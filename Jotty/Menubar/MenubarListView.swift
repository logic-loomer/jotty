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
    /// In-flight calendar refresh, so tests (and reload callers) can await it
    /// deterministically without coupling to the synchronous task path.
    private var calendarTask: Task<Void, Never>?
    /// In-flight delete-event best-effort work, awaited by tests.
    private var deleteTask: Task<Void, Never>?

    init(store: Store,
         timezone: TimeZone = .current,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         calendar: (any CalendarService)? = nil,
         configStore: ConfigStore? = nil) {
        self.store = store
        self.timezone = timezone
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.configStore = configStore
        reload()
    }

    func reload() {
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
            calendarTask = Task { [weak self] in
                await self?.reloadCalendar()
            }
        }
    }

    /// Lazy access gate + today's-events fetch for the read-only Calendar section (SC2).
    /// Authorized -> fetch today's [startOfDay, endOfDay) events; denied -> empty + flag;
    /// notDetermined -> prompt once, then branch. Any thrown error degrades to empty + logs
    /// (never crashes). No-op when no service is injected.
    func reloadCalendar() async {
        guard let calendar else {
            calendarEvents = []
            calendarAccessDenied = false
            return
        }

        // Lazy access gate (RESEARCH): authorized -> fetch; denied -> degrade;
        // notDetermined -> request once then branch on the result.
        let granted: Bool
        switch calendar.access() {
        case .authorized:
            granted = true
        case .denied:
            granted = false
        case .notDetermined:
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

        // SC4: open-time drift awareness. Compare today+future linked tasks against
        // the fetched events; if any drifted (title/time changed externally), surface
        // a one-time calendar-wins sync prompt. Missing events are NOT recreated here
        // (that is the edit-time path); SC4 is read-only awareness + sync-on-confirm.
        let linked = todayAndFutureLinkedTasks(reference: todayStart, calendar: cal)
        let result = CalendarDrift.driftedTasks(linked, against: calendarEvents)
        if !result.drifted.isEmpty {
            driftPrompt = DriftPrompt(drifted: result.drifted)
        }
    }

    /// Linked tasks (calEventID + timeBlock) scheduled today or later — historical
    /// tasks are skipped per CONTEXT (drift checking stays lightweight).
    private func todayAndFutureLinkedTasks(reference todayStart: Date,
                                           calendar cal: Calendar) -> [Todo] {
        tasks.filter { task in
            guard task.calEventID != nil, let tb = task.timeBlock else { return false }
            return tb.start >= todayStart
        }
    }

    /// Awaits the in-flight calendar refresh spawned by the most recent `reload()`.
    /// Test hook (mirrors `CaptureViewModel.awaitCalendarWork`); production fires-and-forgets.
    func awaitCalendarRefresh() async {
        if let t = calendarTask { _ = await t.value }
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
        deleteTask = Task { [weak self] in
            do {
                try await calendar.deleteEvent(id: eventID)
            } catch {
                await MainActor.run {
                    NSLog("[Jotty] calendar deleteEvent failed: \(error.localizedDescription)")
                }
                _ = self
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
            calendarTask = Task { [weak self] in
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
                await self.reloadOnMain()
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
                doc.tasks[idx].text = pair.event.title
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

    private func reloadOnMain() async {
        await MainActor.run { self.reload() }
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
                                    Button(action: { model.toggle(task) }) {
                                        HStack(spacing: 8) {
                                            // Leftovers are filtered by !done, so the box is always empty.
                                            Image(systemName: "square")
                                            Text(task.text)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .contextMenu { taskRowMenu(task) }
                                }
                            }

                            Divider()
                                .padding(.vertical, 2)
                        }

                        ForEach(model.todayTasks, id: \.id) { task in
                            Button(action: { model.toggle(task) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: task.done ? "checkmark.square" : "square")
                                    Text(task.text)
                                        .strikethrough(task.done)
                                        .foregroundStyle(task.done ? .secondary : .primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
    }

    /// Per-row context menu (SC3 affordances): delete, and edit-time for linked tasks.
    @ViewBuilder
    private func taskRowMenu(_ task: Todo) -> some View {
        Button("Delete", role: .destructive) { model.delete(task) }
        if task.calEventID != nil, let tb = task.timeBlock {
            // Edit-time affordance: nudge the linked event +30m as a discoverable
            // demonstration of the edit-time path (the precise picker UI is Phase 8).
            Button("Move +30 min") {
                let newBlock = TimeBlock(start: tb.start.addingTimeInterval(1800),
                                         end: tb.end.addingTimeInterval(1800))
                model.editTime(task, to: newBlock)
            }
        }
    }

    /// Human-readable summary of the drifted tasks for the SC4 prompt.
    private var driftMessage: String {
        let titles = model.driftPrompt?.drifted.map { $0.event.title } ?? []
        if titles.count == 1 {
            return "“\(titles[0])” changed in Calendar. Sync the task to match?"
        }
        return "\(titles.count) tasks changed in Calendar. Sync them to match?"
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
