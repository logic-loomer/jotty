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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tasks.indices, id: \.self) { index in
                        ReviewRowView(
                            task: tasks[index],
                            isChecked: vm.acceptedRowIDs.contains(index),
                            isFocused: focusedRow == index,
                            onToggle: { vm.toggleRow(index) }
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
        .onSubmitKeyCommand { onCommit() }
        // ⌫ — return to input
        .background(KeyMonitorReview(onDelete: onCancel, onDown: {
            let next = (focusedRow ?? -1) + 1
            if next < tasks.count { focusedRow = next }
        }, onUp: {
            let prev = (focusedRow ?? tasks.count) - 1
            if prev >= 0 { focusedRow = prev }
        }, onSpace: {
            if let row = focusedRow { vm.toggleRow(row) }
        }))
    }
}

// MARK: - ReviewRowView

private struct ReviewRowView: View {
    let task: ExtractedTask
    let isChecked: Bool
    let isFocused: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                .font(.system(size: 16))
                .onTapGesture { onToggle() }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isChecked ? Color.primary : Color.secondary)

                if !badges.isEmpty {
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
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var badges: [String] {
        var result: [String] = []
        if let tb = task.timeBlock {
            result.append("📅 " + formatTimeBlock(tb))
        } else if let due = task.dueDate {
            result.append("📅 due " + formatDue(due))
        }
        if task.calendarBlock {
            result.append("[✓] block calendar")
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
private struct KeyMonitorReview: NSViewRepresentable {
    let onDelete: () -> Void
    let onDown: () -> Void
    let onUp: () -> Void
    let onSpace: () -> Void

    func makeNSView(context: Context) -> NSView {
        _ReviewKeyView(onDelete: onDelete, onDown: onDown, onUp: onUp, onSpace: onSpace)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? _ReviewKeyView else { return }
        v.onDelete = onDelete
        v.onDown = onDown
        v.onUp = onUp
        v.onSpace = onSpace
    }
}

private final class _ReviewKeyView: NSView {
    var onDelete: () -> Void
    var onDown: () -> Void
    var onUp: () -> Void
    var onSpace: () -> Void
    private nonisolated(unsafe) var monitor: Any?

    init(onDelete: @escaping () -> Void,
         onDown: @escaping () -> Void,
         onUp: @escaping () -> Void,
         onSpace: @escaping () -> Void) {
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
