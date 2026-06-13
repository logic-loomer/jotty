import AppKit
import SwiftUI

@MainActor
final class MenubarListModel: ObservableObject {
    @Published private(set) var tasks: [Todo] = []
    @Published private(set) var dateLabel: String = ""
    @Published private(set) var leftovers: [Todo] = []
    @Published private(set) var todayTasks: [Todo] = []
    @Published private(set) var leftoversCollapsed: Bool = false

    /// Today's timed calendar events for the read-only menubar section (SC2).
    /// Empty when no service is injected or access is denied; the service already
    /// filters all-day events and sorts by start (plan 03).
    @Published private(set) var calendarEvents: [CalendarEvent] = []
    /// True when calendar access is denied/restricted; the view degrades to a
    /// one-line affordance instead of rows (graceful degradation, never crashes).
    @Published private(set) var calendarAccessDenied: Bool = false

    /// One-time "Also delete the calendar event?" prompt (SC3). Set only when a
    /// linked task is deleted and `deleteCalendarEventWithTask` is still nil
    /// (unanswered); the task is already removed from markdown by then.
    @Published var deletePrompt: DeletePrompt?
    /// Open-time drift prompt (SC4): the linked tasks whose calendar event changed
    /// externally, offered for a calendar-wins sync. Set by `reloadCalendar`.
    @Published var driftPrompt: DriftPrompt?
    /// Linked tasks whose calendar event was deleted in Calendar.app (detected at open time,
    /// CR-02). Surfaced — not silently dropped — so the user is offered a calendar-wins
    /// cleanup: clearing the now-dead `cal_event:` link degrades the task to an unlinked
    /// time-blocked task instead of leaving it pointing at a dead (and recyclable, WR-05) id
    /// forever. Set by `reloadCalendar`; cleared on confirm/dismiss and reset each reload.
    @Published var missingLinkPrompt: MissingLinkPrompt?

    /// Convenience count for the one-line affordance copy.
    var missingLinkCount: Int { missingLinkPrompt?.tasks.count ?? 0 }

    /// Carries the linked tasks whose calendar event was deleted, awaiting a clear decision.
    struct MissingLinkPrompt: Identifiable {
        let id = UUID()
        let tasks: [Todo]
    }

    /// Carries the task awaiting a delete-event decision.
    struct DeletePrompt: Identifiable {
        let id = UUID()
        let task: Todo
    }

    /// Carries the drifted (task, event) pairs awaiting a calendar-wins sync decision.
    struct DriftPrompt: Identifiable {
        let id = UUID()
        let drifted: [(task: Todo, event: CalendarEvent)]
    }

    let store: Store
    /// Exposed so the view can build a timezone-pinned HH:mm formatter that matches
    /// the model's date partitioning (the calendar section renders event start times).
    let timezone: TimeZone
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Optional calendar seam; nil = pure task tool (no calendar section). Plan 08
    /// injects the real EventKit-backed service from AppDelegate.
    private let calendar: (any CalendarService)?
    /// Optional config store for the remembered delete-event preference (SC3).
    /// nil-defaulted so existing tests/callers construct the model without it; when
    /// nil, a linked delete falls back to NOT touching the calendar (safe default).
    private let configStore: ConfigStore?
    /// Optional Send-to-Claude seam (SC1). nil-defaulted like calendar/configStore so
    /// existing tests/callers construct the model without it; when nil, the "Send to
    /// Claude" menu item is a no-op (AppDelegate injects the real SystemClaudeHandoff).
    private let claudeHandoff: (any ClaudeHandoff)?

    /// One-line, transient notice shown when Code-mode Send-to-Claude finds no `claude`
    /// binary (D-SC1 graceful degrade): points the user to Web mode. Cleared by the view
    /// after a brief display. nil = nothing to show.
    @Published var claudeNotice: String?
    /// In-flight calendar refresh spawned by `reload()`, so tests (and reload callers) can
    /// await it deterministically. Kept distinct from `editTask` (WR-03) so an edit and a
    /// concurrent refresh never overwrite each other's handle and drop in-flight work.
    private var refreshTask: Task<Void, Never>?
    /// In-flight edit-time update/recreate work spawned by `editTime()`. Distinct from
    /// `refreshTask`: `editTime` ends by triggering a `reload()` (which sets `refreshTask`),
    /// so sharing one handle would let the reload clobber the edit handle before a test
    /// could observe it (WR-03).
    private var editTask: Task<Void, Never>?
    /// In-flight delete-event best-effort work, awaited by tests.
    private var deleteTask: Task<Void, Never>?

    init(store: Store,
         timezone: TimeZone = .current,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         calendar: (any CalendarService)? = nil,
         configStore: ConfigStore? = nil,
         claudeHandoff: (any ClaudeHandoff)? = nil) {
        self.store = store
        self.timezone = timezone
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.configStore = configStore
        self.claudeHandoff = claudeHandoff
        reload()
    }

    /// Day-partition key for a task: its `createdAt` day in the model's timezone.
    /// Used by the row affordances (rename / move / open day file) so they always
    /// address the file the task actually lives in.
    private func dayOf(_ task: Todo) -> Date { task.createdAt }

    /// `clearMissingLinks` is forwarded to the spawned calendar refresh: it is true on a
    /// genuine open-time reload (popover open, foreground, midnight) so a deleted event's
    /// dead link self-heals (CR-02), but false when reload runs as the tail of an edit-time
    /// create/update, so the self-heal never races the just-written id (see `reloadCalendar`).
    func reload(clearMissingLinks: Bool = true) {
        // Single snapshot: grouping, collapse key, and dateLabel must all
        // derive from the same instant (midnight Timer reloads an open popover).
        let snapshot = now()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let todayStart = cal.startOfDay(for: snapshot)

        do {
            let doc = try store.readDoc(on: snapshot)
            tasks = doc.tasks
        } catch {
            tasks = []
        }
        leftovers = tasks.filter { cal.startOfDay(for: $0.createdAt) < todayStart && !$0.done }
        todayTasks = tasks.filter { !(cal.startOfDay(for: $0.createdAt) < todayStart && !$0.done) }

        let todayKey = collapseKey(for: snapshot)
        leftoversCollapsed = defaults.bool(forKey: todayKey)
        // Housekeeping: drop every stale collapse key from earlier days
        // (the app may not run every day, so "yesterday only" leaks keys).
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("leftoversCollapsed-") && key != todayKey {
            defaults.removeObject(forKey: key)
        }

        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.timeZone = timezone
        dateLabel = f.string(from: snapshot)

        // Calendar refresh rides on every reload trigger (popover open, window
        // close, midnight Timer) so the read section + future drift hooks stay
        // fresh. The task path above stays synchronous; calendar is async/best-effort.
        if calendar != nil {
            refreshTask = Task { [weak self] in
                await self?.reloadCalendar(clearMissingLinks: clearMissingLinks)
            }
        }
    }

    /// Lazy access gate + today's-events fetch for the read-only Calendar section (SC2).
    /// Authorized -> fetch today's [startOfDay, endOfDay) events; denied -> empty + flag;
    /// notDetermined -> prompt once (only when `promptIfUndetermined` is true), then branch.
    /// Any thrown error degrades to empty + logs (never crashes). No-op when no service is
    /// injected.
    ///
    /// `promptIfUndetermined` defaults to true so explicit user actions (popover open, edit)
    /// can drive the one-time access prompt. `applicationDidBecomeActive` passes `false`
    /// (WR-06): foreground activation must NOT re-issue the TCC prompt on every activation
    /// while the grant is still `notDetermined` — a denied result is already terminal
    /// (`access()` maps `.denied`/`.restricted` to `.denied`, so the `notDetermined` branch is
    /// never re-entered once the user has answered).
    func reloadCalendar(promptIfUndetermined: Bool = true,
                        clearMissingLinks: Bool = true) async {
        guard let calendar else {
            calendarEvents = []
            calendarAccessDenied = false
            return
        }

        // Lazy access gate (RESEARCH): authorized -> fetch; denied -> degrade;
        // notDetermined -> request once (only when allowed) then branch on the result.
        let granted: Bool
        switch calendar.access() {
        case .authorized:
            granted = true
        case .denied:
            granted = false
        case .notDetermined:
            // Foreground activation must not prompt (WR-06): if not allowed to prompt, leave
            // the section empty WITHOUT flagging denial, so a later user action can still ask.
            guard promptIfUndetermined else {
                calendarEvents = []
                calendarAccessDenied = false
                return
            }
            granted = await calendar.requestAccess() == .authorized
        }

        guard granted else {
            calendarEvents = []
            calendarAccessDenied = true
            return
        }
        calendarAccessDenied = false

        // Today's range in the model's timezone (matches task partitioning).
        let snapshot = now()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let todayStart = cal.startOfDay(for: snapshot)
        guard let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) else {
            calendarEvents = []
            return
        }

        do {
            // Service filters all-day + sorts by start (plan 03).
            calendarEvents = try await calendar.eventsInRange(start: todayStart, end: todayEnd)
        } catch {
            // Best-effort: a read failure degrades to no rows, never crashes capture/UI.
            NSLog("[Jotty] calendar read failed: \(error.localizedDescription)")
            calendarEvents = []
            return
        }

        // SC4: open-time drift awareness. Compare today's linked tasks against the fetched
        // events. Drifted (title/time changed externally) -> a one-time calendar-wins sync
        // prompt. Missing (event deleted in Calendar) -> the dead `cal_event:` link is
        // cleared so the task degrades cleanly to an unlinked time-blocked task, and the
        // count is surfaced (CR-02 — calendar wins; a deleted event must not leave a task
        // pointing at a dead/recyclable id forever).
        //
        // `linked` is scoped to the SAME window the read fetched (`[todayStart, todayEnd)`),
        // not "today+future": storage is one file per day and `reload()` only loads today's
        // file, so a future-day task could never appear in `calendarEvents` and would be
        // mis-classified as missing (WR-02).
        let linked = todayLinkedTasks(from: todayStart, to: todayEnd)
        let result = CalendarDrift.driftedTasks(linked, against: calendarEvents)
        if !result.drifted.isEmpty {
            driftPrompt = DriftPrompt(drifted: result.drifted)
        }
        // Surface (do NOT silently drop, CR-02) tasks whose linked event was deleted in
        // Calendar, offering a calendar-wins cleanup. Only on a genuine open-time refresh: a
        // reload that FOLLOWS an edit-time create/update would otherwise race the just-written
        // id against a not-yet-refreshed fetch and mis-classify it as missing, so the edit
        // path passes `clearMissingLinks: false` (CR-02 must not fight the SC3 edit flow).
        if clearMissingLinks {
            missingLinkPrompt = result.missing.isEmpty
                ? nil
                : MissingLinkPrompt(tasks: result.missing)
        }
    }

    /// Linked tasks (calEventID + timeBlock) whose block falls inside the fetched window
    /// `[start, end)`. Scope matches the today-only read + one-file-per-day storage (WR-02);
    /// historical and future-day tasks are structurally out of scope.
    private func todayLinkedTasks(from start: Date, to end: Date) -> [Todo] {
        tasks.filter { task in
            guard task.calEventID != nil, let tb = task.timeBlock else { return false }
            return tb.start >= start && tb.start < end
        }
    }

    /// Confirms the missing-link prompt (CR-02): clears the now-dead `cal_event:` link from
    /// each surfaced task. Calendar wins — the task keeps its time block but is unlinked, so a
    /// later edit re-creates a fresh event rather than risking an update against a recycled
    /// EventKit identifier (WR-05). Best-effort + idempotent: a disk failure logs, never crashes.
    func confirmClearMissingLinks() {
        guard let prompt = missingLinkPrompt else { return }
        missingLinkPrompt = nil
        let snapshot = now()
        do {
            var doc = try store.readDoc(on: snapshot)
            let missingIDs = Set(prompt.tasks.map(\.id))
            var cleared = false
            for idx in doc.tasks.indices where missingIDs.contains(doc.tasks[idx].id)
                && doc.tasks[idx].calEventID != nil {
                doc.tasks[idx].calEventID = nil
                cleared = true
            }
            if cleared {
                try store.replaceTasks(doc.tasks, on: snapshot)
            }
        } catch {
            NSLog("[Jotty] clearing dead calendar links failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Dismisses the missing-link prompt, leaving the (dead) links in place ("Keep").
    func dismissMissingLinkPrompt() {
        missingLinkPrompt = nil
    }

    /// Awaits all in-flight calendar work (edit-time update/recreate, then the refresh it
    /// triggers) spawned by the most recent `editTime()`/`reload()`. Test hook (mirrors
    /// `CaptureViewModel.awaitCalendarWork`); production fires-and-forgets. Awaiting the edit
    /// task FIRST then the refresh task it spawns makes test sequencing deterministic (WR-03).
    func awaitCalendarRefresh() async {
        if let t = editTask { _ = await t.value }
        if let t = refreshTask { _ = await t.value }
    }

    func setCollapsed(_ collapsed: Bool, at date: Date? = nil) {
        leftoversCollapsed = collapsed
        defaults.set(collapsed, forKey: collapseKey(for: date ?? now()))
    }

    func toggle(_ task: Todo) {
        // Membership must be captured BEFORE the store write and reload():
        // reload repartitions the arrays and a just-completed leftover vanishes.
        let wasLeftover = leftovers.contains { $0.id == task.id }
        // Single snapshot: the store write and the collapse key must agree
        // on the day even if the wall clock crosses midnight mid-call.
        let snapshot = now()
        do {
            try store.toggleTodo(id: task.id, on: snapshot)
            // Auto-collapse only on the day's FIRST interaction; a manual
            // expand/collapse (key present) is the user's choice and wins.
            // Gated on write success: a failed toggle is not an interaction.
            if wasLeftover, defaults.object(forKey: collapseKey(for: snapshot)) == nil {
                // Same animation as the manual header toggle.
                withAnimation(.easeInOut(duration: 0.15)) {
                    setCollapsed(true, at: snapshot)
                }
            }
        } catch {
            NSLog("[Jotty] toggle failed: \(error.localizedDescription)")
        }
        reload()
    }

    // MARK: - Delete (SC3)

    /// Deletes a task. The markdown line is removed immediately (disk is the source
    /// of truth, T-5-09 — a calendar failure never blocks the local delete). If the
    /// task had a linked calendar event, the remembered `deleteCalendarEventWithTask`
    /// preference decides: nil -> surface a one-time prompt; true -> delete the event
    /// best-effort; false -> leave the event. The remembered choice is acted on
    /// silently thereafter.
    func delete(_ task: Todo) {
        let snapshot = now()
        do {
            try store.deleteTodo(id: task.id, on: snapshot)
        } catch {
            NSLog("[Jotty] delete failed: \(error.localizedDescription)")
        }

        if let eventID = task.calEventID {
            switch configStore?.config.deleteCalendarEventWithTask {
            case .some(true):
                bestEffortDeleteEvent(id: eventID)
            case .some(false):
                break // remembered: leave the event.
            case .none:
                // Unanswered (nil pref, or no config store) -> ask once.
                deletePrompt = DeletePrompt(task: task)
            }
        }
        reload()
    }

    /// Resolves the one-time delete-event prompt: persists the answer (so the next
    /// linked delete acts silently) and, on "yes", deletes the linked event
    /// best-effort. The task was already removed from markdown by `delete(_:)`.
    func resolveDeletePrompt(deleteEvent: Bool) {
        guard let prompt = deletePrompt else { return }
        deletePrompt = nil
        try? configStore?.update { $0.deleteCalendarEventWithTask = deleteEvent }
        if deleteEvent, let eventID = prompt.task.calEventID {
            bestEffortDeleteEvent(id: eventID)
        }
    }

    /// Awaits the in-flight best-effort delete-event work (test hook).
    func awaitDeleteWork() async {
        if let t = deleteTask { _ = await t.value }
    }

    /// Fires the calendar delete on a detached task; a failure logs but never
    /// rolls back the already-completed markdown delete (best-effort, T-5-09).
    private func bestEffortDeleteEvent(id eventID: String) {
        guard let calendar else { return }
        // No `self` is needed inside the task (the log runs on the main actor without it),
        // so capture nothing rather than a now-unused `[weak self]` + `_ = self` no-op (IN-05).
        deleteTask = Task {
            do {
                try await calendar.deleteEvent(id: eventID)
            } catch {
                await MainActor.run {
                    NSLog("[Jotty] calendar deleteEvent failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Edit time (SC3)

    /// Changes a task's time block. The markdown `time:` token is updated immediately
    /// (disk first, T-5-09); if the task is linked to a calendar event, the event is
    /// updated in place by id. When the event is gone (.eventNotFound), it is
    /// recreated and the new id rewritten onto the task line (recreate-and-relink per
    /// CONTEXT/RESEARCH). Other calendar errors are logged, never blocking.
    func editTime(_ task: Todo, to newBlock: TimeBlock) {
        let snapshot = now()
        do {
            try store.updateTodoTime(id: task.id, timeBlock: newBlock, on: snapshot)
        } catch {
            NSLog("[Jotty] editTime failed: \(error.localizedDescription)")
        }

        if let calendar, let eventID = task.calEventID {
            let title = CalendarDrift.sanitize(title: task.text)
            editTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await calendar.updateEvent(id: eventID, title: title,
                                                   start: newBlock.start, end: newBlock.end)
                } catch CalendarError.eventNotFound {
                    // Event deleted in Calendar: recreate + rewrite the new id (SC3).
                    await self.recreateAndRelink(task: task, title: title, block: newBlock,
                                                 on: snapshot, calendar: calendar)
                } catch {
                    await MainActor.run {
                        NSLog("[Jotty] calendar updateEvent failed: \(error.localizedDescription)")
                    }
                }
                // Skip the dead-link self-heal on the edit's trailing reload: the id was just
                // (re)written and a stale/empty fetch must not clear it (CR-02 vs SC3).
                await self.reloadOnMain(clearMissingLinks: false)
            }
        } else {
            reload()
        }
    }

    /// Recreates a missing linked event and rewrites the new id onto the task line.
    private func recreateAndRelink(task: Todo, title: String, block: TimeBlock,
                                   on date: Date, calendar: any CalendarService) async {
        do {
            let newID = try await calendar.createEvent(title: title,
                                                       start: block.start, end: block.end)
            await MainActor.run {
                do {
                    var doc = try self.store.readDoc(on: date)
                    if let idx = doc.tasks.firstIndex(where: { $0.id == task.id }) {
                        doc.tasks[idx].timeBlock = block
                        doc.tasks[idx].calEventID = newID
                        try self.store.replaceTasks(doc.tasks, on: date)
                    }
                } catch {
                    NSLog("[Jotty] recreate-relink rewrite failed: \(error.localizedDescription)")
                }
            }
        } catch {
            await MainActor.run {
                NSLog("[Jotty] calendar createEvent (recreate) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Drift sync (SC4)

    /// Confirms the open-time drift prompt: calendar wins. Each drifted task's text
    /// and time block are rewritten to match its calendar event, persisted via
    /// replaceTasks (T-5-10 — user-confirmed, scoped to the drifted linked tasks).
    func confirmDriftSync() {
        guard let prompt = driftPrompt else { return }
        driftPrompt = nil
        let snapshot = now()
        do {
            var doc = try store.readDoc(on: snapshot)
            for pair in prompt.drifted {
                guard let idx = doc.tasks.firstIndex(where: { $0.id == pair.task.id }) else { continue }
                // Store the SANITIZED title (WR-04): drift is detected via
                // `sanitize(task.text) != event.title`, and create writes `sanitize(text)`
                // as the event title. Writing the raw event title back into `task.text`
                // would be asymmetric — the next open recomputes `sanitize(newText)`, which
                // can differ from `event.title` and re-trigger drift on every open. It also
                // keeps markdown-significant chars out of the parser-sensitive task line (IN-01).
                doc.tasks[idx].text = CalendarDrift.sanitize(title: pair.event.title)
                doc.tasks[idx].timeBlock = TimeBlock(start: pair.event.start, end: pair.event.end)
            }
            try store.replaceTasks(doc.tasks, on: snapshot)
        } catch {
            NSLog("[Jotty] drift sync failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Dismisses the drift prompt, leaving the markdown unchanged ("Keep mine").
    func dismissDriftPrompt() {
        driftPrompt = nil
    }

    private func reloadOnMain(clearMissingLinks: Bool = true) async {
        await MainActor.run { self.reload(clearMissingLinks: clearMissingLinks) }
    }

    // MARK: - Row affordances (SC1 / SC4)

    /// Moves the task to tomorrow's file (SC4). Disk is the source of truth: the
    /// store removes it from today and lands it on tomorrow (re-partitioned createdAt),
    /// then we reload so it leaves today's list. A linked calendar event is left
    /// untouched here (the time block keeps its wall-clock slot on the new day; a
    /// later edit re-syncs the event). A failure logs, never crashes.
    func moveToTomorrow(_ task: Todo) {
        do {
            try store.moveTodoToTomorrow(id: task.id, on: dayOf(task))
        } catch {
            NSLog("[Jotty] moveToTomorrow failed: \(error.localizedDescription)")
        }
        reload()
    }

    /// Opens the markdown day file the task lives in (SC4). Read-only reveal in the
    /// user's default .md handler; never mutates state. No-op only when the file path
    /// cannot be resolved (it always can — DailyFile derives a deterministic path).
    func openDayFile(_ task: Todo) {
        let url = DailyFile.url(in: store.folder, on: dayOf(task), timezone: store.timezone)
        NSWorkspace.shared.open(url)
    }

    /// Hands the task off to Claude (SC1). Wraps the task text in the prompt template
    /// once (`ClaudePrompt.wrapped`) — the handoff takes the FINAL prompt — and routes
    /// it through the injected seam. When Code mode reports no `claude` binary
    /// (`send` returns false), surface a one-line notice pointing to Web mode
    /// (D-SC1 graceful degrade). No-op when no handoff is injected.
    func sendToClaude(_ task: Todo) {
        guard let claudeHandoff else { return }
        let prompt = ClaudePrompt.wrapped(task.text)
        let delivered = claudeHandoff.send(prompt: prompt)
        if !delivered {
            claudeNotice = "Claude Code isn’t available — switch to Web mode in Settings → AI."
        }
    }

    /// Commits an inline rename (SC4). The store rewrites only the task's text,
    /// preserving id + every metadata token, and rejects an empty-after-trim rename
    /// (no write — the caller reverts the UI). Disk stays the source of truth; we
    /// reload so the list reflects the new text. A failure logs, never crashes.
    func rename(_ task: Todo, to text: String) {
        do {
            try store.renameTodo(id: task.id, text: text, on: dayOf(task))
        } catch {
            NSLog("[Jotty] rename failed: \(error.localizedDescription)")
        }
        reload()
    }

    var doneCount: Int { tasks.filter(\.done).count }

    private func collapseKey(for date: Date) -> String {
        let f = DateFormatter()
        // Fixed-format machine-readable key: pin POSIX locale so region
        // calendar settings (Buddhist/Japanese era years) cannot skew it.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timezone
        return "leftoversCollapsed-\(f.string(from: date))"
    }
}

struct MenubarListView: View {
    @ObservedObject var model: MenubarListModel
    let onCapture: () -> Void
    let onSettings: () -> Void

    /// The "+30 min" nudge interval used by the discoverable edit-time affordance (IN-04).
    private static let nudgeSeconds: TimeInterval = 30 * 60

    // MARK: - Inline rename state (SC4)

    /// The id of the task currently being renamed inline, or nil when no row is in
    /// edit mode. Click a title to enter edit mode; commit (Return/blur) or cancel
    /// (Esc) clears it. Tracked by id (not the Todo) so a mid-edit reload that
    /// re-fetches the task does not drop the editor.
    @State private var editingTaskID: String?
    /// The in-progress draft text for the row being renamed. Seeded with the task's
    /// current text on entry; committed via `model.rename` or discarded on cancel.
    @State private var renameDraft: String = ""
    /// Drives first-responder focus for the inline rename field inside the NSPopover
    /// (RESEARCH Pitfall 2: set true on appear, with a DispatchQueue.main.async nudge,
    /// so the field actually gets the caret and keystrokes).
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Jotty · \(model.dateLabel)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.doneCount) of \(model.tasks.count) done")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Task list
            if model.tasks.isEmpty {
                Text("No tasks today. ⌘N to capture.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Yesterday's leftovers — dedicated section above today's tasks.
                        if !model.leftovers.isEmpty {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    model.setCollapsed(!model.leftoversCollapsed)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: model.leftoversCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("Yesterday · \(model.leftovers.count)")
                                        .font(.system(size: 11, weight: .semibold))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)

                            if !model.leftoversCollapsed {
                                ForEach(model.leftovers, id: \.id) { task in
                                    HStack(spacing: 8) {
                                        // Leftovers are filtered by !done, so the box is always empty.
                                        Button(action: { model.toggle(task) }) {
                                            Image(systemName: "square")
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        rowTitle(task, isLeftover: true)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .contextMenu { taskRowMenu(task) }
                                }
                            }

                            Divider()
                                .padding(.vertical, 2)
                        }

                        ForEach(model.todayTasks, id: \.id) { task in
                            HStack(spacing: 8) {
                                Button(action: { model.toggle(task) }) {
                                    Image(systemName: task.done ? "checkmark.square" : "square")
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                rowTitle(task, isLeftover: false)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .contextMenu { taskRowMenu(task) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 300)
            }

            // Read-only Calendar section (SC2): today's timed events as `·` rows,
            // a degraded one-liner on denial, nothing when authorized-but-empty.
            calendarSection

            // CR-02: surface tasks whose linked event was deleted in Calendar and whose
            // dead `cal_event:` link was just cleared (one-line, non-blocking).
            missingLinkNotice

            Divider()

            // Footer
            HStack(spacing: 0) {
                Button("Capture") { onCapture() }
                    .keyboardShortcut("n", modifiers: .command)
                Spacer()
                Button("Settings") { onSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        // SC3: one-time "Also delete the calendar event?" prompt. The task is
        // already removed from markdown; this only governs the linked event.
        .alert("Also delete the calendar event?",
               isPresented: Binding(
                   get: { model.deletePrompt != nil },
                   set: { if !$0 { model.deletePrompt = nil } })) {
            Button("Delete event", role: .destructive) {
                model.resolveDeletePrompt(deleteEvent: true)
            }
            Button("Keep event", role: .cancel) {
                model.resolveDeletePrompt(deleteEvent: false)
            }
        } message: {
            Text("Your choice is remembered for future deletions.")
        }
        // SC4: open-time drift sync prompt (calendar wins on confirm).
        .alert("Sync from Calendar?",
               isPresented: Binding(
                   get: { model.driftPrompt != nil },
                   set: { if !$0 { model.driftPrompt = nil } })) {
            Button("Sync") { model.confirmDriftSync() }
            Button("Keep mine", role: .cancel) { model.dismissDriftPrompt() }
        } message: {
            Text(driftMessage)
        }
        // SC1 graceful degrade: Code-mode Send-to-Claude with no `claude` binary
        // surfaces a one-line notice pointing to Web mode (D-SC1).
        .alert("Send to Claude",
               isPresented: Binding(
                   get: { model.claudeNotice != nil },
                   set: { if !$0 { model.claudeNotice = nil } })) {
            Button("OK", role: .cancel) { model.claudeNotice = nil }
        } message: {
            Text(model.claudeNotice ?? "")
        }
    }

    /// Per-row context menu (SC1 + SC3 + SC4): the full four-item set —
    /// Delete · Move to tomorrow · Open day file · Send to Claude — plus the
    /// Phase-5 edit-time "Move +30 min" affordance for linked tasks (kept so SC3
    /// edit-time does not regress).
    @ViewBuilder
    private func taskRowMenu(_ task: Todo) -> some View {
        Button("Delete", role: .destructive) { model.delete(task) }
        Button("Move to tomorrow") { model.moveToTomorrow(task) }
        Button("Open day file") { model.openDayFile(task) }
        Button("Send to Claude") { model.sendToClaude(task) }
        if task.calEventID != nil, let tb = task.timeBlock {
            Divider()
            // Edit-time affordance: nudge the linked event +30m as a discoverable
            // demonstration of the edit-time path (the precise picker UI is Phase 8).
            Button("Move +30 min") {
                let newBlock = TimeBlock(start: tb.start.addingTimeInterval(Self.nudgeSeconds),
                                         end: tb.end.addingTimeInterval(Self.nudgeSeconds))
                model.editTime(task, to: newBlock)
            }
        }
    }

    // MARK: - Inline rename (SC4)

    /// The task title: a tappable `Text` normally, an editable `TextField` while this
    /// row is in rename mode. Click the title to enter edit mode; commit on Return
    /// (`onSubmit`) AND on focus loss (`renameFieldFocused` flips false), Esc cancels
    /// (revert, no write). Empty-after-trim commit reverts (the Store rejects it).
    @ViewBuilder
    private func rowTitle(_ task: Todo, isLeftover: Bool) -> some View {
        if editingTaskID == task.id {
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($renameFieldFocused)
                .onAppear {
                    renameDraft = task.text
                    // RESEARCH Pitfall 2: nudge first-responder on the next runloop so
                    // the field reliably gets the caret inside the NSPopover.
                    DispatchQueue.main.async { renameFieldFocused = true }
                }
                .onSubmit { commitRename(task) }
                .onExitCommand { cancelRename() }   // Esc → cancel, no write
                .onChange(of: renameFieldFocused) { _, focused in
                    // Blur commits (mirrors Return); guard on still-editing this row so a
                    // post-commit focus flip does not double-fire.
                    if !focused, editingTaskID == task.id { commitRename(task) }
                }
        } else {
            Text(task.text)
                .strikethrough(task.done)
                .foregroundStyle(rowTextStyle(task, isLeftover: isLeftover))
                .contentShape(Rectangle())
                .onTapGesture { beginRename(task) }
        }
    }

    private func rowTextStyle(_ task: Todo, isLeftover: Bool) -> HierarchicalShapeStyle {
        if isLeftover { return .secondary }
        return task.done ? .secondary : .primary
    }

    private func beginRename(_ task: Todo) {
        renameDraft = task.text
        editingTaskID = task.id
    }

    /// Commits the draft via the model (Store rejects empty-after-trim → the reload
    /// reverts the UI to the persisted text), then exits edit mode.
    private func commitRename(_ task: Todo) {
        let draft = renameDraft
        editingTaskID = nil
        renameFieldFocused = false
        model.rename(task, to: draft)
    }

    /// Cancels edit mode without writing (Esc): disk stays the source of truth.
    private func cancelRename() {
        editingTaskID = nil
        renameFieldFocused = false
    }

    /// Human-readable summary of the drifted tasks for the SC4 prompt.
    private var driftMessage: String {
        let titles = model.driftPrompt?.drifted.map { $0.event.title } ?? []
        if titles.count == 1 {
            return "“\(titles[0])” changed in Calendar. Sync the task to match?"
        }
        return "\(titles.count) tasks changed in Calendar. Sync them to match?"
    }

    // MARK: - Missing-link notice (CR-02)

    /// One-line affordance shown when one or more linked tasks had their calendar event
    /// deleted in Calendar.app (CR-02). Tapping clears the now-dead `cal_event:` links so the
    /// tasks degrade to plain time-blocked tasks (calendar wins). Nothing when zero.
    @ViewBuilder
    private var missingLinkNotice: some View {
        if model.missingLinkCount > 0 {
            Divider()
            Button(action: { model.confirmClearMissingLinks() }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 9, weight: .semibold))
                    Text(model.missingLinkCount == 1
                         ? "1 linked event was deleted in Calendar. Clear the dead link?"
                         : "\(model.missingLinkCount) linked events were deleted in Calendar. Clear the dead links?")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Calendar section (SC2)

    /// Timezone-pinned HH:mm formatter for event start times; matches the model's
    /// date partitioning so a row's time reads in the same zone as the rest of the view.
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        f.timeZone = model.timezone
        return f
    }

    @ViewBuilder
    private var calendarSection: some View {
        if model.calendarAccessDenied {
            Divider()
            // Graceful degradation: a single non-crashing line, no rows.
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text("Calendar access not granted — enable in System Settings")
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if !model.calendarEvents.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 1)

                ForEach(model.calendarEvents) { event in
                    Button(action: { openInCalendar(event) }) {
                        HStack(spacing: 8) {
                            // `·` bullet — read-only, visually distinct from task checkboxes.
                            Text("·")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(timeFormatter.string(from: event.start))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(event.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
            .padding(.bottom, 6)
        }
        // Authorized-but-empty: render nothing (keep the popover tidy).
    }

    /// Opens Calendar.app at the event's date via `calshow:` (date-level, not
    /// per-event — there is no public per-event deep link on macOS, RESEARCH Pitfall 5).
    private func openInCalendar(_ event: CalendarEvent) {
        if let url = CalendarURL.show(for: event.start) {
            NSWorkspace.shared.open(url)
        }
    }
}
