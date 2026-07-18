import AppKit
import SwiftUI

struct MenubarListView: View {
    @ObservedObject var model: MenubarListModel
    let onCapture: () -> Void
    let onSettings: () -> Void
    /// Toggles the ⌘K command bar (#2) — the SAME `toggleCommandBar()` the global
    /// hotkey calls, routed through MenubarController so the popover closes first.
    /// nil-defaulted so existing tests/previews build the view without it.
    var onCommandBar: () -> Void = {}
    /// Opens the calendar canvas window (Phase 8 SC4 / CALX-04) via
    /// AppDelegate's `openCalendarCanvas()`; this header item is the canvas's
    /// only entry point (menubar-item-only, IN-01). The canvas is an OPTIONAL
    /// alternative surface — this popover stays the default.
    let onOpenCanvas: () -> Void

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

    // MARK: - Snooze date picker state (Phase 8 SC3)

    /// The task awaiting a "Pick a date…" snooze choice, or nil when the picker
    /// sheet is closed. Confirming calls `model.snooze(task, to: snoozeDraftDate)`.
    @State private var snoozePickTask: Todo?
    /// The in-progress date for the snooze picker sheet; seeded with the model's
    /// now()-anchored tomorrow on entry (CR-01 — never task.createdAt).
    @State private var snoozeDraftDate: Date = Date()

    // MARK: - Command bar highlight (Phase 9, SC3)

    /// Opacity of the accent wash on the row named by `model.highlightedTaskID`,
    /// driven 1 → 0 by `beginHighlight`. View-local: the fade is presentation,
    /// only the id lives on the model (unit-tested state machine).
    @State private var highlightOpacity: Double = 0
    /// Snap the wash away instead of animating the ~1.5 s fade (A11Y).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                // #10: the date + "N of M done" summary read as ONE header element
                // (VoiceOver rotor stop), combining the two Texts and ignoring the
                // raw children in favour of a spoken-friendly label.
                HStack {
                    Text("Jotty · \(model.dateLabel)")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(model.visibleDoneCount) of \(model.visibleTasks.count) done")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Jotty, \(model.dateLabel). \(model.visibleDoneCount) of \(model.visibleTasks.count) tasks done.")

                // Phase 8 SC4: the "Calendar canvas" item — the canvas's only
                // entry point; opens the optional window via AppDelegate.
                Button(action: onOpenCanvas) {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Calendar canvas")
                .accessibilityLabel("Open calendar canvas")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // #7: transient, dismissible banner when a damaged day file was recovered
            // (quarantined to a `.corrupt-*` sidecar before a write).
            corruptQuarantineBanner

            // roadmap 3.4 phase 2, Task 6: transient, dismissible banner when
            // today's file had an unresolved iCloud sync conflict (the losing
            // versions were archived to `.conflict-*` sidecars before iCloud's
            // own conflict list was cleared).
            unresolvedConflictBanner

            // I1 (final review): transient banner when a reload could not READ
            // today's file — the list on screen may be stale, not empty.
            reloadFailureBanner

            // roadmap 2.3: transient, dismissible banner when a task-wins "Update
            // event" push could not update one or more linked events.
            driftUpdateSkipNoticeBanner

            // Suggested section (Phase 7, SC2): external inbox items offered for
            // Accept/Dismiss, ABOVE the task list. Renders only when the inbox service
            // is wired AND has suggestions; nothing on the default/unconfigured config.
            if let inboxService = model.inboxService {
                SuggestedSection(service: inboxService,
                                 onAccept: { model.acceptSuggestion($0) },
                                 onDismiss: { model.dismissSuggestion($0) })
            }

            // Task list
            if model.visibleTasks.isEmpty {
                Text("No tasks today. ⌘N to capture.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // ScrollViewReader wraps the task list so a command-bar highlight
                // can scroll its row into view (CalendarCanvasView scrollTo idiom).
                ScrollViewReader { proxy in
                ScrollView {
                    // LazyVStack so a day with hundreds of tasks only builds the rows
                    // actually on screen (#3) — the ScrollViewReader highlight still
                    // scrolls to a row by `.id`. Was an eager VStack.
                    LazyVStack(alignment: .leading, spacing: 4) {
                        // Earlier leftovers (everything older than today, not just
                        // yesterday — UX-05 honest labelling) above today's tasks.
                        if !model.leftovers.isEmpty {
                            Button(action: {
                                // #11: honour Reduce Motion — nil animation snaps the
                                // leftovers collapse instead of easing it.
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                                    model.setCollapsed(!model.leftoversCollapsed)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: model.leftoversCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                    Text("Earlier · \(model.leftovers.count)")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            // #10: rotor-navigable section header for the leftovers group.
                            .accessibilityAddTraits(.isHeader)

                            if !model.leftoversCollapsed {
                                ForEach(model.leftovers, id: \.id) { task in
                                    HStack(spacing: 8) {
                                        // Leftovers are filtered by !done, so the box is always empty.
                                        Button(action: { model.toggle(task) }) {
                                            Image(systemName: "square")
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        // A11Y-01: leftovers are always not-done, so the
                                        // label is the single actionable direction.
                                        .accessibilityLabel("Mark done")
                                        rowTitle(task, isLeftover: true)
                                        metadataBadges(task)
                                        // UX-05: origin date for rows older than yesterday
                                        // (the "Earlier" header already implies yesterday).
                                        if let origin = model.originLabel(for: task) {
                                            Text(origin)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        rowOverflowMenu(task)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .background(highlightWash(for: task.id))
                                    .id(MenubarListModel.rowID(task, isLeftover: true))
                                    .contextMenu { taskRowMenu(task) }
                                }
                            }

                            Divider()
                                .padding(.vertical, 2)
                        }

                        // Today's OPEN tasks render inline; completed ones drop into
                        // the collapsible "Done · N" group below (#4).
                        ForEach(model.todayOpen, id: \.id) { task in
                            todayRow(task)
                        }

                        if !model.todayDone.isEmpty {
                            Button(action: {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                                    model.setDoneCollapsed(!model.doneCollapsed)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: model.doneCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                    Text("Done · \(model.todayDone.count)")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            // #10: rotor-navigable section header for the done group.
                            .accessibilityAddTraits(.isHeader)

                            if !model.doneCollapsed {
                                ForEach(model.todayDone, id: \.id) { task in
                                    todayRow(task)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 300)
                // The controller applies the highlight AFTER popover.show, so the
                // publish lands as a change; onAppear covers a re-shown popover
                // whose content view is rebuilt with the id already set.
                .onChange(of: model.highlightedTaskID) { _, newID in
                    guard let newID else { return }
                    beginHighlight(newID, proxy: proxy)
                }
                .onAppear {
                    if let id = model.highlightedTaskID {
                        beginHighlight(id, proxy: proxy)
                    }
                }
                }
            }

            // Read-only Calendar section (SC2): today's timed events as `·` rows,
            // a degraded one-liner on denial, nothing when authorized-but-empty.
            calendarSection

            // CR-02: surface tasks whose linked event was deleted in Calendar and whose
            // dead `cal_event:` link was just cleared (one-line, non-blocking).
            missingLinkNotice

            // #2: discoverable ⌘K entry — a "Search…" affordance revealing the
            // flagship command bar plus its LIVE combo (the bar was dispatchable
            // but invisible in the running UI).
            searchAffordance

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
            .font(.callout)
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
        // SC4: open-time drift sync prompt. "Sync" = calendar wins (rewrite the task
        // from the event); "Update event" = task wins (roadmap 2.3 — push the task's
        // own fields to the event); "Keep mine" dismisses, leaving both sides as-is.
        .alert("Sync from Calendar?",
               isPresented: Binding(
                   get: { model.driftPrompt != nil },
                   set: { if !$0 { model.driftPrompt = nil } })) {
            Button("Sync") { model.confirmDriftSync() }
            Button("Update event") { model.confirmDriftUpdateEvent() }
            Button("Keep mine", role: .cancel) { model.dismissDriftPrompt() }
        } message: {
            Text(driftMessage)
        }
        // Roadmap 3.3 slice 2: the ONE-SHOT bulk re-anchor prompt after a live timezone
        // change. "Times moved with you" pushes each task's re-anchored wall-clock onto its
        // event (2.3 push-mine, in bulk); "Keep appointment times" pins each task back to its
        // event's absolute instants (SC4 calendar-wins, in bulk); dismiss decides later (the
        // shift re-detects on the next open). Fires only when the per-block partition found
        // pairs that moved by exactly the zone-offset delta — genuine drift stays on the
        // normal "Sync from Calendar?" prompt above.
        .alert("Your timezone changed",
               isPresented: Binding(
                   get: { model.reanchorPrompt != nil },
                   set: { if !$0 { model.reanchorPrompt = nil } })) {
            Button("Times moved with you") { model.confirmReanchorMoveWithMe() }
            Button("Keep appointment times") { model.confirmReanchorKeepTimes() }
            Button("Decide later", role: .cancel) { model.dismissReanchorPrompt() }
        } message: {
            Text(reanchorMessage)
        }
        // SC5 parity for menubar-initiated moves ("Move +30 min" runs the same overlap
        // gate as capture/drop). Mirrors the canvas alert: the isPresented setter is
        // INERT (WR-04) — the buttons own the decision, and the model clears
        // `pendingDropConflict` inside `resolveDropConflict`, which flips this false.
        .alert("Time conflict",
               isPresented: Binding(
                   get: { model.pendingDropConflict != nil },
                   set: { _ in })) {
            Button(model.pendingDropConflict?.kind == .move ? "Move anyway" : "Create anyway") {
                model.resolveDropConflict(commitAnyway: true)
            }
            Button("Cancel", role: .cancel) { model.resolveDropConflict(commitAnyway: false) }
        } message: {
            Text(Self.conflictMessage(for: model.pendingDropConflict))
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
        // SC3: "Pick a date…" snooze sheet — a date-only picker; confirming
        // persists via model.snooze (visibility only, never relocation).
        .sheet(isPresented: Binding(
                   get: { snoozePickTask != nil },
                   set: { if !$0 { snoozePickTask = nil } })) {
            snoozeDatePickerSheet
        }
    }

    /// The "Pick a date…" snooze sheet: a compact date-only picker with
    /// Cancel/Snooze actions. Kept deliberately small (Claude discretion per
    /// CONTEXT — no over-building; the graphical picker is one tap per date).
    private var snoozeDatePickerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze until")
                .font(.headline)
            DatePicker("", selection: $snoozeDraftDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Cancel") { snoozePickTask = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Snooze") {
                    if let task = snoozePickTask {
                        model.snooze(task, to: snoozeDraftDate)
                    }
                    snoozePickTask = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// Per-row context menu (SC1 + SC3 + SC4): the full four-item set —
    /// Delete · Move to tomorrow · Open day file · Send to Claude — plus the
    /// Phase-5 edit-time "Move +30 min" affordance for linked tasks (kept so SC3
    /// edit-time does not regress). SINGLE shared builder (UX-11): both the hidden
    /// `.contextMenu` and the visible per-row overflow `Menu` render THIS content,
    /// so the two surfaces can never drift.
    @ViewBuilder
    private func taskRowMenu(_ task: Todo) -> some View {
        Button("Delete", role: .destructive) { model.delete(task) }
        Button("Move to tomorrow") { model.moveToTomorrow(task) }
        Button("Open day file") { model.openDayFile(task) }
        sendToClaudeItem(task)
        // Phase 8: recurrence rule (SC2 UI surface) + snooze-until-date (SC3).
        repeatSubmenu(task)
        snoozeSubmenu(task)
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

    // MARK: - Repeat + Snooze-to submenus (Phase 8 SC2/SC3)

    /// Weekday names indexed by gregorian weekday int - 1 (1=Sun…7=Sat), for the
    /// Custom recurrence toggles.
    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                       "Thursday", "Friday", "Saturday"]

    /// The Repeat submenu (SC2 UI): None/Daily/Weekdays/Weekly write the rule via
    /// `model.setRecurrence`; Custom nests a lightweight Sun…Sat toggle set feeding
    /// `.custom(Set<Int>)`. The active rule carries a checkmark.
    @ViewBuilder
    private func repeatSubmenu(_ task: Todo) -> some View {
        Menu("Repeat") {
            recurrenceChoice("None", rule: nil, for: task)
            recurrenceChoice("Daily", rule: .daily, for: task)
            recurrenceChoice("Weekdays", rule: .weekday, for: task)
            weeklyChoice(task)
            customWeekdaysSubmenu(task)
        }
    }

    /// The Weekly Repeat choice (sweep INFO): sets weekly on the weekday the user
    /// PICKS it (today's weekday via `model.currentWeekday`), captured in the
    /// `weekly:<wd>` token — not the task's createdAt weekday. The checkmark
    /// matches ANY stored `.weekly(_)`, so it shows regardless of which weekday
    /// the rule was set on.
    @ViewBuilder
    private func weeklyChoice(_ task: Todo) -> some View {
        let isWeekly: Bool = { if case .weekly = task.recur { return true }; return false }()
        Button(action: { model.setRecurrence(task, to: .weekly(model.currentWeekday)) }) {
            if isWeekly {
                Label("Weekly", systemImage: "checkmark")
            } else {
                Text("Weekly")
            }
        }
    }

    /// A single Repeat choice; the currently active rule shows a checkmark.
    @ViewBuilder
    private func recurrenceChoice(_ title: String, rule: Recurrence?, for task: Todo) -> some View {
        Button(action: { model.setRecurrence(task, to: rule) }) {
            if task.recur == rule {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// The Custom recurrence picker (Claude discretion per CONTEXT): a simple
    /// Sun…Sat toggle set — each tap flips that weekday's membership in the
    /// task's `.custom` set and persists immediately (an empty set clears the
    /// rule, matching `Recurrence.parse`'s rejection of empty customs).
    private func customWeekdaysSubmenu(_ task: Todo) -> some View {
        let selected: Set<Int> = {
            if case .custom(let days) = task.recur { return days }
            return []
        }()
        return Menu("Custom") {
            ForEach(1..<8, id: \.self) { day in
                Button {
                    var days = selected
                    if days.contains(day) { days.remove(day) } else { days.insert(day) }
                    model.setRecurrence(task, to: days.isEmpty ? nil : .custom(days))
                } label: {
                    if selected.contains(day) {
                        Label(Self.weekdayNames[day - 1], systemImage: "checkmark")
                    } else {
                        Text(Self.weekdayNames[day - 1])
                    }
                }
            }
        }
    }

    /// The Snooze-to submenu (SC3): Tomorrow / Next week use the model's
    /// now()-anchored convenience dates (CR-01); "Pick a date…" opens the
    /// date-only picker sheet.
    @ViewBuilder
    private func snoozeSubmenu(_ task: Todo) -> some View {
        Menu("Snooze to…") {
            Button("Tomorrow") { model.snooze(task, to: model.snoozeTomorrowDate) }
            Button("Next week") { model.snooze(task, to: model.snoozeNextWeekDate) }
            Divider()
            Button("Pick a date…") {
                snoozeDraftDate = model.snoozeTomorrowDate
                snoozePickTask = task
            }
        }
    }

    /// The Send-to-Claude item with its key equivalent visible (UX-07 menubar half).
    /// The LIVE `.sendToClaude` combo (rebindable in Settings → Keybindings) renders
    /// natively via `.keyboardShortcut` for character keys, or as a displayString
    /// suffix for special keys the SwiftUI shortcut cannot carry. No bound combo (or
    /// no injected store) degrades to the plain item — never a hardcoded literal.
    @ViewBuilder
    private func sendToClaudeItem(_ task: Todo) -> some View {
        if let combo = model.sendToClaudeCombo {
            if let shortcut = combo.swiftUIShortcut {
                Button("Send to Claude") { model.sendToClaude(task) }
                    .keyboardShortcut(shortcut)
            } else {
                Button("Send to Claude (\(combo.displayString))") { model.sendToClaude(task) }
            }
        } else {
            Button("Send to Claude") { model.sendToClaude(task) }
        }
    }

    /// UX-11: visible, VoiceOver-labelled entry point to the row's actions — the
    /// SAME `taskRowMenu` builder the hidden `.contextMenu` uses, so the overflow
    /// menu and the context menu carry identical items by construction.
    @ViewBuilder
    private func rowOverflowMenu(_ task: Todo) -> some View {
        Menu {
            taskRowMenu(task)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Task actions")
    }

    // MARK: - Command bar highlight rendering (Phase 9, SC3)

    /// Scrolls the highlighted row to center and runs the one-shot wash fade:
    /// full opacity, easing out over ~1.5 s (snapped away with no animation when
    /// Reduce Motion is on), then a generation-scoped clear (review WR-04): the
    /// asyncAfter captures THIS trigger's `model.highlightGeneration`, so a
    /// timer whose trigger was superseded — a second ⌘K → Enter within 1.5 s,
    /// or a timer surviving a torn-down view instance — is a total no-op and
    /// can never snap away or clear the newer highlight mid-fade.
    private func beginHighlight(_ id: String, proxy: ScrollViewProxy) {
        let generation = model.highlightGeneration
        // Rows carry section-qualified identities (`MenubarListModel.rowID`), so
        // the bare task id must be resolved to the section the task renders in.
        proxy.scrollTo(model.rowScrollID(for: id), anchor: .center)
        highlightOpacity = 1
        if !reduceMotion {
            withAnimation(.easeOut(duration: 1.5)) { highlightOpacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard generation == model.highlightGeneration else { return }
            highlightOpacity = 0   // reduce-motion path: snap, no fade
            model.clearHighlight(ifGeneration: generation)
        }
    }

    /// The accent wash behind the highlighted row; nothing for every other row.
    @ViewBuilder
    private func highlightWash(for taskID: String) -> some View {
        if model.highlightedTaskID == taskID {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.15))
                .opacity(highlightOpacity)
        }
    }

    // MARK: - Inline rename (SC4)

    /// One of today's task rows — shared by the OPEN list and the "Done · N" group
    /// (#4) so both render identically (checkbox, title, badges, overflow, context
    /// menu, highlight wash). Leftovers keep their own row (they carry an origin
    /// date), so this is today-only.
    @ViewBuilder
    private func todayRow(_ task: Todo) -> some View {
        HStack(spacing: 8) {
            Button(action: { model.toggle(task) }) {
                Image(systemName: task.done ? "checkmark.square" : "square")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A11Y-01: state-dynamic label — announces the action the toggle takes.
            .accessibilityLabel(task.done ? "Mark not done" : "Mark done")
            rowTitle(task, isLeftover: false)
            metadataBadges(task)
            Spacer()
            rowOverflowMenu(task)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(highlightWash(for: task.id))
        .id(MenubarListModel.rowID(task, isLeftover: false))
        .contextMenu { taskRowMenu(task) }
    }

    /// The task title: a tappable `Text` normally, an editable `TextField` while this
    /// row is in rename mode. Click the title to enter edit mode; commit on Return
    /// (`onSubmit`) AND on focus loss (`renameFieldFocused` flips false), Esc cancels
    /// (revert, no write). Empty-after-trim commit reverts (the Store rejects it).
    @ViewBuilder
    private func rowTitle(_ task: Todo, isLeftover: Bool) -> some View {
        if editingTaskID == task.id {
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($renameFieldFocused)
                .onAppear {
                    renameDraft = task.text
                    // RESEARCH Pitfall 2: nudge first-responder on the next runloop so
                    // the field reliably gets the caret inside the NSPopover.
                    DispatchQueue.main.async { renameFieldFocused = true }
                }
                .onSubmit { commitRename(id: task.id) }
                .onExitCommand { cancelRename() }   // Esc → cancel, no write
                .onChange(of: renameFieldFocused) { _, focused in
                    // Blur commits (mirrors Return); guard on still-editing this row so a
                    // post-commit focus flip does not double-fire. Commit by id (WR-04) so a
                    // mid-edit reload that re-diffs the ForEach cannot land the draft on a
                    // different row than the one being edited.
                    if !focused, editingTaskID == task.id { commitRename(id: task.id) }
                }
        } else {
            Text(task.text)
                .strikethrough(task.done)
                .foregroundStyle(rowTextStyle(task, isLeftover: isLeftover))
                .contentShape(Rectangle())
                .onTapGesture { beginRename(task) }
                // A11Y-01: tap-gesture text is invisible to VoiceOver as a
                // control — expose the button trait and explain the action.
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Double-tap to rename")
        }
    }

    private func rowTextStyle(_ task: Todo, isLeftover: Bool) -> HierarchicalShapeStyle {
        if isLeftover { return .secondary }
        return task.done ? .secondary : .primary
    }

    // MARK: - Metadata badges (#3)

    /// Compact metadata pills for a task row — the menubar list was the only
    /// surface that was metadata-blind (Review + command bar already show badges).
    /// Renders, in order: an HH:mm time-block pill, a relative due-date pill (tinted
    /// orange with a `!` when overdue), and a recurring glyph. All strings come from
    /// the SHARED `TaskBadge` formatter so every surface agrees. Nothing when the
    /// task carries no metadata.
    @ViewBuilder
    private func metadataBadges(_ task: Todo) -> some View {
        let glyph = TaskBadge.recurringGlyph(task)
        if task.timeBlock != nil || task.dueDate != nil || glyph != nil {
            let cal = model.badgeCalendar
            let asOf = model.badgeAsOf
            HStack(spacing: 4) {
                if let tb = task.timeBlock {
                    badgePill(TaskBadge.timeBlockPill(tb, timezone: model.timezone),
                              a11y: "At \(TaskBadge.timeBlockPill(tb, timezone: model.timezone))")
                }
                if let due = task.dueDate {
                    let overdue = TaskBadge.isOverdue(task, asOf: asOf, calendar: cal)
                    let label = TaskBadge.dueLabel(due, asOf: asOf, calendar: cal)
                    badgePill(label,
                              systemImage: overdue ? "exclamationmark.circle" : nil,
                              tint: overdue ? .orange : .secondary,
                              a11y: overdue ? "Overdue, due \(label)" : "Due \(label)")
                }
                if let glyph {
                    Image(systemName: glyph)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Repeats")
                }
            }
        }
    }

    /// A single rounded metadata pill with an optional leading glyph + tint. The
    /// `a11y` label replaces the raw glyph/text for VoiceOver.
    @ViewBuilder
    private func badgePill(_ text: String,
                           systemImage: String? = nil,
                           tint: Color = .secondary,
                           a11y: String) -> some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y)
    }

    private func beginRename(_ task: Todo) {
        // Clicking a second row's title while another rename is in progress must not
        // silently discard the first row's typed text — flush it as a commit first
        // (mirrors the blur-commit path; commitRename re-resolves by id and no-ops
        // if the row is gone, and the Store rejects an empty-after-trim draft).
        if let current = editingTaskID, current != task.id {
            commitRename(id: current)
        }
        renameDraft = task.text
        editingTaskID = task.id
    }

    /// Commits the draft for the row identified by `id` (WR-04). Captures the draft, exits
    /// edit mode, clears the shared draft, then RE-RESOLVES the task from the model at
    /// commit time — so a mid-edit `reload()` (midnight Timer / `applicationDidBecomeActive`)
    /// that re-diffs the `ForEach` cannot let a stale captured `Todo` write the draft onto a
    /// row whose identity changed under it. A no-longer-present id is a safe no-op (Store
    /// also rejects empty-after-trim → the reload reverts the UI to the persisted text).
    private func commitRename(id: String) {
        let draft = renameDraft
        editingTaskID = nil
        renameFieldFocused = false
        renameDraft = ""
        guard let task = model.tasks.first(where: { $0.id == id }) else { return }
        model.rename(task, to: draft)
    }

    /// Cancels edit mode without writing (Esc): disk stays the source of truth. Clears the
    /// shared draft so a later edit never inherits a stale value.
    private func cancelRename() {
        editingTaskID = nil
        renameFieldFocused = false
        renameDraft = ""
    }

    /// Kind-aware conflict copy, shared with the canvas alert so the two surfaces can
    /// never drift: a `.move` cancel changes nothing (the gate runs before any write);
    /// a `.create` cancel skips only the event (the time: block is already on disk).
    static func conflictMessage(for conflict: CalendarConflict?) -> String {
        let title = conflict?.conflictTitle ?? ""
        if conflict?.kind == .move {
            return "This slot overlaps “\(title)”. Cancel keeps the task where it was."
        }
        return "This slot overlaps “\(title)”. "
            + "The task keeps its time either way; Cancel skips creating the calendar event."
    }

    /// Human-readable summary of the drifted tasks for the SC4 prompt (M3): the copy
    /// names BOTH resolution directions, since the alert offers three buttons — "Sync"
    /// (calendar wins) AND "Update event" (task wins) — not just the one-way sync the old
    /// single-direction copy implied.
    private var driftMessage: String {
        let titles = model.driftPrompt?.drifted.map { $0.event.title } ?? []
        if titles.count == 1 {
            return "“\(titles[0])” changed in Calendar. "
                + "Sync the task to match, or update the event from the task?"
        }
        return "\(titles.count) tasks changed in Calendar. "
            + "Sync them to match, or update the events from the tasks?"
    }

    /// Human-readable summary for the one-shot bulk re-anchor prompt (roadmap 3.3).
    /// M1: beyond the count, a SMALL set (≤3) lists each affected title with its old→new
    /// times — the wall-clock the block kept (what the user always typed) → where the
    /// untouched event now displays in the new zone — so the choice is concrete rather than
    /// an opaque number. Times use the model's zone-pinned HH:mm formatter.
    private var reanchorMessage: String {
        let pairs = model.reanchorPrompt?.tzShift ?? []
        let count = pairs.count
        let subject = count == 1 ? "1 calendar-linked block" : "\(count) calendar-linked blocks"
        let base = "\(subject) kept their wall-clock times when your timezone changed. "
            + "Move the events to match, or keep them pinned to the original appointment times?"
        guard count > 0, count <= 3 else { return base }
        let f = model.timeFormatter
        let lines = pairs.map { pair -> String in
            let kept = pair.task.timeBlock.map { f.string(from: $0.start) } ?? "?"
            let appointment = f.string(from: pair.event.start)
            return "• “\(pair.event.title)”: \(kept) → \(appointment)"
        }
        return base + "\n\n" + lines.joined(separator: "\n")
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
                        .font(.caption.weight(.semibold))
                    Text(model.missingLinkCount == 1
                         ? "1 linked event was deleted in Calendar. Clear the dead link?"
                         : "\(model.missingLinkCount) linked events were deleted in Calendar. Clear the dead links?")
                        .font(.subheadline)
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

    // MARK: - Corrupt-file quarantine banner (#7)

    /// A brief, dismissible recovery banner shown when Cluster A's quarantine fired
    /// (a damaged day file was backed up before a write). Non-blocking: it stays until
    /// the user taps dismiss (so a popover-open reload never hides it before it's seen),
    /// and a rebuilt model starts clean.
    @ViewBuilder
    private var corruptQuarantineBanner: some View {
        if let notice = model.corruptQuarantineNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { model.dismissCorruptQuarantineNotice() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss recovery notice")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: - iCloud conflict-sibling banner (roadmap 3.4 phase 2, Task 6)

    /// A brief, dismissible recovery banner shown when `Store.
    /// checkForUnresolvedConflicts` found today's file had an unresolved
    /// iCloud sync conflict (the losing versions were archived to
    /// `.conflict-*` sidecars). Mirrors `corruptQuarantineBanner` exactly in
    /// style and dismiss idiom: non-blocking, stays until the user taps
    /// dismiss (so a popover-open reload never hides it before it's seen),
    /// and a rebuilt model starts clean.
    @ViewBuilder
    private var unresolvedConflictBanner: some View {
        if let notice = model.unresolvedConflictNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { model.dismissUnresolvedConflictNotice() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss conflict notice")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: - Reload read-failure banner (I1, final review)

    /// A brief, dismissible banner shown when a `reload()` could not read today's
    /// file (I1): the visible list is the previous, stale-but-visible one rather
    /// than an empty popover. Mirrors `corruptQuarantineBanner`'s style/dismiss
    /// idiom; additionally, a later successful reload clears the notice on its own.
    @ViewBuilder
    private var reloadFailureBanner: some View {
        if let notice = model.reloadFailureNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { model.dismissReloadFailureNotice() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss reload notice")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: - "Update event" skip notice (roadmap 2.3)

    /// A brief, dismissible banner shown when a task-wins "Update event" push could
    /// not update one or more linked events (deleted in Calendar, or a foreign event
    /// the WR-05 marker guard refused). Mirrors `corruptQuarantineBanner`'s pattern.
    @ViewBuilder
    private var driftUpdateSkipNoticeBanner: some View {
        if let notice = model.driftUpdateSkipNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { model.dismissDriftUpdateSkipNotice() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update-event notice")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: - Search affordance (#2)

    /// The discoverable ⌘K entry point: a full-width "Search…" row with a
    /// magnifying-glass glyph and the LIVE command-bar combo on the trailing edge
    /// (reuses the `sendToClaudeItem` live-combo pattern via `model.commandBarCombo`).
    /// Tapping toggles the SAME command bar the global hotkey opens — the view holds
    /// no local ⌘K equivalent (Pitfall 10), so this is a click affordance, not a
    /// keyboard shortcut.
    @ViewBuilder
    private var searchAffordance: some View {
        Divider()
        Button(action: { onCommandBar() }) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                Text("Search…")
                    .font(.subheadline)
                Spacer()
                if let combo = model.commandBarCombo {
                    Text(combo.displayString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityLabel(searchAffordanceLabel)
    }

    /// VoiceOver label naming the action AND the live combo (never a hardcoded key).
    private var searchAffordanceLabel: String {
        if let combo = model.commandBarCombo {
            return "Search tasks and actions, \(combo.displayString)"
        }
        return "Search tasks and actions"
    }

    // MARK: - Calendar section (SC2)

    @ViewBuilder
    private var calendarSection: some View {
        if model.calendarAccessDenied {
            Divider()
            // Graceful degradation: a single non-crashing line, no rows.
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                Text("Calendar access not granted — enable in System Settings")
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if !model.visibleCalendarEvents.isEmpty || !model.visibleAllDayEvents.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 1)
                    // #10: rotor-navigable section header.
                    .accessibilityAddTraits(.isHeader)

                // All-day chips (deadlines, PTO, holidays): the compact signal row the
                // timed list can't carry — the mapper drops all-day rows from it by
                // design (they aren't conflict material and have no meaningful time).
                allDayChipRow

                // A busy day's events get their OWN capped scroll so the list can never
                // grow unbounded and push the footer off-screen (#1). The header above
                // stays fixed; every event stays reachable by scrolling. LazyVStack so a
                // long agenda only builds the rows actually on screen.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.visibleCalendarEvents) { event in
                            Button(action: { openInCalendar(event) }) {
                                HStack(spacing: 8) {
                                    // `·` bullet — read-only, distinct from task checkboxes.
                                    Text("·")
                                        .font(.callout.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    Text(model.timeFormatter.string(from: event.start))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(event.title)
                                        .font(.callout)
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
                }
                .frame(maxHeight: 150)
            }
            .padding(.bottom, 6)
        }
        // Authorized-but-empty: render nothing (keep the popover tidy).
    }

    /// The all-day chip row: one capsule per all-day event, horizontally scrollable
    /// when a day carries several. Tapping opens Calendar.app at the day, same as a
    /// timed row. Renders nothing when the day has no (visible) all-day events.
    @ViewBuilder
    private var allDayChipRow: some View {
        if !model.visibleAllDayEvents.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.visibleAllDayEvents) { event in
                        Button(action: { openInCalendar(event) }) {
                            Text(event.title)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("All-day: \(event.title)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 2)
        }
    }

    /// Opens Calendar.app at the event's date via `calshow:` (date-level, not
    /// per-event — there is no public per-event deep link on macOS, RESEARCH Pitfall 5).
    private func openInCalendar(_ event: CalendarEvent) {
        if let url = CalendarURL.show(for: event.start) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Key-equivalent rendering (UX-07)

private extension KeyCombo {
    /// SwiftUI shortcut for single-character keys (e.g. K + cmd renders the native
    /// key-equivalent column in the menu item); nil for special keys (Space, F-keys,
    /// arrows…), which fall back to a displayString-suffixed label instead.
    var swiftUIShortcut: KeyboardShortcut? {
        let name = KeyCombo.keyName(for: keyCode)
        guard name.count == 1, let ch = name.lowercased().first else { return nil }
        var mods: EventModifiers = []
        if modifiers.contains(.cmd)   { mods.insert(.command) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.opt)   { mods.insert(.option) }
        if modifiers.contains(.ctrl)  { mods.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(ch), modifiers: mods)
    }
}

// MARK: - Suggested section (Phase 7, SC2)

/// The menubar "Suggested" section: external inbox items (assigned GitHub issues,
/// review-requested PRs, …) offered for Accept / Dismiss, distinct from tasks and
/// calendar rows. It `@ObservedObject`s the `InboxService` directly so a refresh's
/// `@Published suggestions` update redraws live. Renders NOTHING when the suggestion
/// list is empty (default/unconfigured config), keeping the popover tidy.
private struct SuggestedSection: View {
    @ObservedObject var service: InboxService
    let onAccept: (InboxItem) -> Void
    let onDismiss: (InboxItem) -> Void

    /// A11Y-02: the source-glyph column is a fixed DIMENSION (14pt at default
    /// size) that aligns rows in the 300pt popover — scale it with the user's
    /// text preference instead of hardcoding the width.
    @ScaledMetric(relativeTo: .subheadline) private var sourceGlyphWidth: CGFloat = 14

    var body: some View {
        if !service.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggested")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 1)
                    // #10: rotor-navigable section header.
                    .accessibilityAddTraits(.isHeader)

                ForEach(service.suggestions) { item in
                    HStack(spacing: 8) {
                        Image(systemName: InboxSourceGlyph.glyph(for: item.sourceID))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: sourceGlyphWidth)
                        Text(item.title.isEmpty ? item.rawText : item.title)
                            .font(.callout)
                            .lineLimit(1)
                            .help(item.url)
                        Spacer(minLength: 4)
                        // Accept → writes a source:/source_url: task; Dismiss → never re-suggest.
                        Button(action: { onAccept(item) }) {
                            Image(systemName: "plus.circle")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Accept — add to today's tasks")
                        // A11Y-01: .help() tooltips are NOT VoiceOver labels
                        // (RESEARCH Pattern 10) — keep the tooltip AND label.
                        .accessibilityLabel("Accept suggestion")
                        Button(action: { onDismiss(item) }) {
                            Image(systemName: "xmark.circle")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss — never suggest again")
                        .accessibilityLabel("Dismiss suggestion")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
            .padding(.bottom, 6)

            Divider()
        }
    }

}

/// SF Symbol per inbox source id; defaults to a generic inbox glyph for
/// unmapped sources. Hoisted from `SuggestedSection` (where it was private) so
/// the ⌘K command bar's Inbox rows reuse the SAME mapping instead of
/// duplicating it (09-05 Task 1).
enum InboxSourceGlyph {
    static func glyph(for sourceID: String) -> String {
        switch sourceID {
        case "github":   return "chevron.left.forwardslash.chevron.right"
        case "calendar": return "calendar"
        case "gmail":  return "envelope"
        case "slack":  return "number"
        case "linear": return "line.3.horizontal"
        case "notion": return "doc.text"
        default:       return "tray"
        }
    }
}
