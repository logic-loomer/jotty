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

    let store: Store
    private let timezone: TimeZone
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Optional calendar seam; nil = pure task tool (no calendar section). Plan 08
    /// injects the real EventKit-backed service from AppDelegate.
    private let calendar: (any CalendarService)?
    /// In-flight calendar refresh, so tests (and reload callers) can await it
    /// deterministically without coupling to the synchronous task path.
    private var calendarTask: Task<Void, Never>?

    init(store: Store,
         timezone: TimeZone = .current,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         calendar: (any CalendarService)? = nil) {
        self.store = store
        self.timezone = timezone
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
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
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 300)
            }

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
    }
}
