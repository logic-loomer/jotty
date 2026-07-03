import SwiftUI

// MARK: - ReviewListView

/// Displayed after extraction completes. Shows checkbox rows for each ExtractedTask
/// with metadata badges. ⌘↩ commits checked rows; ⌫ returns to input.
struct ReviewListView: View {
    @ObservedObject var vm: CaptureViewModel
    let tasks: [ExtractedTask]
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focusedRow: Int?

    // UX-10: edit-in-place state (menubar inline-rename idiom transplant, SC4).
    // One row edits at a time; the list owns the shared draft + focus.
    @State private var editingIndex: Int?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool

    private func errorMessage(for error: AIProviderError) -> String {
        switch error {
        case .guardrail:
            return "Apple Intelligence couldn't process this capture. It's been saved as a plain note — edit tasks manually."
        case .modelUnavailable(let reason):
            return "AI extraction unavailable (\(reason)). Capture saved as a plain note."
        case .contextOverflow:
            return "Capture too long for on-device extraction. Saved as a plain note."
        case .underlying:
            return "AI extraction failed. Capture saved as a plain note."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // AI-SPEC §4.6 / §6.3: inline error banner when extraction failed.
            if let error = vm.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 12))
                    Text(errorMessage(for: error))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.12))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tasks.indices, id: \.self) { index in
                        ReviewRowView(
                            task: tasks[index],
                            isChecked: vm.acceptedRowIDs.contains(index),
                            isFocused: focusedRow == index,
                            isCalendarOn: vm.calendarEnabledRowIDs.contains(index),
                            isEditing: editingIndex == index,
                            renameDraft: $renameDraft,
                            renameFieldFocused: $renameFieldFocused,
                            onToggle: { vm.toggleRow(index) },
                            onCalendarToggle: { vm.toggleCalendarRow(index) },
                            onBeginEdit: { beginRename(index) },
                            onCommitEdit: { commitRename(index: index) },
                            onCancelEdit: { cancelRename() }
                        )
                        .focused($focusedRow, equals: index)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedRow = index }
                    }
                }
                .padding(.vertical, 8)
            }

            HStack {
                Spacer()
                Text("⌘↩ commit  ·  ⌫ back")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 520, height: 280)
        .onAppear {
            if !tasks.isEmpty {
                DispatchQueue.main.async { focusedRow = 0 }
            }
        }
        // ⌘↩ — commit
        .onSubmitKeyCommand {
            // UX-10: a mid-edit ⌘↩ lands the in-flight rename FIRST so the review
            // commits the title the user can see, not the stale pre-edit one.
            if let index = editingIndex { commitRename(index: index) }
            onCommit()
        }
        // ⌫ — return to input. While a title is being edited (UX-10) the monitor
        // passes every key through so ⌫/space/↑/↓ type into the TextField instead
        // of cancelling the review or toggling rows.
        .background(KeyMonitorReview(isEditingTitle: { editingIndex != nil },
                                     onDelete: onCancel, onDown: {
            let next = (focusedRow ?? -1) + 1
            if next < tasks.count { focusedRow = next }
        }, onUp: {
            let prev = (focusedRow ?? tasks.count) - 1
            if prev >= 0 { focusedRow = prev }
        }, onSpace: {
            if let row = focusedRow { vm.toggleRow(row) }
        }))
    }

    // MARK: - Inline rename (UX-10) — menubar SC4 idiom transplant

    /// Enters edit mode for `index`, seeding the shared draft with the current title.
    private func beginRename(_ index: Int) {
        renameDraft = tasks[index].title
        editingIndex = index
    }

    /// Commits the draft for `index`, guarded on still-editing-that-row so the
    /// post-commit focus flip cannot double-fire (mirrors the menubar commit-by-id
    /// guard). Empty-after-trim reverts inside the VM (renameReviewRow no-ops).
    private func commitRename(index: Int) {
        guard editingIndex == index else { return }
        let draft = renameDraft
        editingIndex = nil
        renameFieldFocused = false
        renameDraft = ""
        vm.renameReviewRow(index, title: draft)
    }

    /// Cancels edit mode without writing (Esc): the extracted title stays as-is.
    /// Clears the shared draft so a later edit never inherits a stale value.
    private func cancelRename() {
        editingIndex = nil
        renameFieldFocused = false
        renameDraft = ""
    }
}

// MARK: - ReviewRowView

private struct ReviewRowView: View {
    let task: ExtractedTask
    let isChecked: Bool
    let isFocused: Bool
    /// UX-06: whether this row's per-item calendar toggle is ON (event will be created).
    let isCalendarOn: Bool
    /// UX-10: whether this row is in title-edit mode (list-level `editingIndex`).
    let isEditing: Bool
    /// UX-10: shared rename draft owned by the list (one edit at a time).
    @Binding var renameDraft: String
    /// UX-10: list-owned focus for the rename field (Pitfall 8 nudge applies).
    var renameFieldFocused: FocusState<Bool>.Binding
    let onToggle: () -> Void
    /// UX-06: flips this row's calendar toggle (vm.toggleCalendarRow).
    let onCalendarToggle: () -> Void
    /// UX-10: enters edit mode for this row (list seeds the draft).
    let onBeginEdit: () -> Void
    /// UX-10: commits the draft (list guards on still-editing-this-row).
    let onCommitEdit: () -> Void
    /// UX-10: cancels edit mode without writing (Esc).
    let onCancelEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                .font(.system(size: 16))
                .onTapGesture { onToggle() }

            VStack(alignment: .leading, spacing: 3) {
                titleView

                if !badges.isEmpty || task.timeBlock != nil {
                    HStack(spacing: 6) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        // UX-06: interactive per-row calendar toggle — replaces the old
                        // non-interactive string badge. Only rows with a time block can
                        // create an event, so only they show it.
                        // Direct button action on @Published state; no onChange needed.
                        if task.timeBlock != nil {
                            Button(action: onCalendarToggle) {
                                HStack(spacing: 3) {
                                    Image(systemName: isCalendarOn
                                          ? "calendar.badge.checkmark" : "calendar")
                                        .foregroundStyle(isCalendarOn
                                                         ? Color.accentColor : Color.secondary)
                                    Text(isCalendarOn ? "calendar event" : "no event")
                                        .font(.system(size: 11))
                                        .foregroundStyle(isCalendarOn
                                                         ? Color.accentColor : Color.secondary)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help("Creates a calendar event")
                            .accessibilityLabel(isCalendarOn
                                                ? "Calendar event on" : "Calendar event off")
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    /// UX-10: the row title — a tappable `Text` normally, an editable `TextField`
    /// while this row is in edit mode (the verified menubar inline-rename idiom:
    /// commit on Return AND focus loss, Esc cancels, empty-after-trim reverts in
    /// the VM). Title tap EDITS; the checkbox tap TOGGLES — separate gestures.
    @ViewBuilder
    private var titleView: some View {
        if isEditing {
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(renameFieldFocused)
                .onAppear {
                    renameDraft = task.title
                    // RESEARCH Pitfall 8: the floating capture window is not key
                    // when SwiftUI applies the assignment — nudge first-responder
                    // on the next runloop so the field reliably gets the caret.
                    DispatchQueue.main.async { renameFieldFocused.wrappedValue = true }
                }
                .onSubmit { onCommitEdit() }
                .onExitCommand { onCancelEdit() }   // Esc → cancel, no write
                .onChange(of: renameFieldFocused.wrappedValue) { _, focused in
                    // Blur commits (mirrors Return); the list's commitRename(index:)
                    // guards on still-editing-this-row so a post-commit focus flip
                    // cannot double-fire.
                    if !focused { onCommitEdit() }
                }
        } else {
            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(isChecked ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
                .onTapGesture { onBeginEdit() }
                .accessibilityHint("Double-tap to edit title")
        }
    }

    private var badges: [String] {
        var result: [String] = []
        if let tb = task.timeBlock {
            result.append("📅 " + formatTimeBlock(tb))
        } else if let due = task.dueDate {
            result.append("📅 due " + formatDue(due))
        }
        return result
    }

    private func formatDue(_ date: Date) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6:
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"   // full weekday name
            return fmt.string(from: date)
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }

    private func formatTimeBlock(_ tb: TimeBlock) -> String {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(tb.start)
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "H:mm"
        let range = "\(timeFmt.string(from: tb.start))–\(timeFmt.string(from: tb.end))"
        if isToday {
            return "today \(range)"
        } else {
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEE"
            return "\(dayFmt.string(from: tb.start)) \(range)"
        }
    }
}

// MARK: - Keyboard monitor for review state

/// Monitors ⌫, ↑, ↓, space keys while in Review state.
/// UX-10: while a title is being edited, EVERY key passes through untouched so the
/// rename TextField receives ⌫/space/↑/↓ as text editing instead of review actions.
private struct KeyMonitorReview: NSViewRepresentable {
    let isEditingTitle: () -> Bool
    let onDelete: () -> Void
    let onDown: () -> Void
    let onUp: () -> Void
    let onSpace: () -> Void

    func makeNSView(context: Context) -> NSView {
        _ReviewKeyView(isEditingTitle: isEditingTitle,
                       onDelete: onDelete, onDown: onDown, onUp: onUp, onSpace: onSpace)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? _ReviewKeyView else { return }
        v.isEditingTitle = isEditingTitle
        v.onDelete = onDelete
        v.onDown = onDown
        v.onUp = onUp
        v.onSpace = onSpace
    }
}

private final class _ReviewKeyView: NSView {
    var isEditingTitle: () -> Bool
    var onDelete: () -> Void
    var onDown: () -> Void
    var onUp: () -> Void
    var onSpace: () -> Void
    private nonisolated(unsafe) var monitor: Any?

    init(isEditingTitle: @escaping () -> Bool,
         onDelete: @escaping () -> Void,
         onDown: @escaping () -> Void,
         onUp: @escaping () -> Void,
         onSpace: @escaping () -> Void) {
        self.isEditingTitle = isEditingTitle
        self.onDelete = onDelete
        self.onDown = onDown
        self.onUp = onUp
        self.onSpace = onSpace
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let window = self.window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            // UX-10: an in-flight title edit owns the keyboard — pass through.
            if self.isEditingTitle() { return event }
            let noMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            switch event.keyCode {
            case 51 where noMods:   // ⌫ (delete/backspace)
                self.onDelete(); return nil
            case 125 where noMods:  // ↓
                self.onDown(); return nil
            case 126 where noMods:  // ↑
                self.onUp(); return nil
            case 49 where noMods:   // space
                self.onSpace(); return nil
            default:
                return event
            }
        }
    }

    nonisolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
