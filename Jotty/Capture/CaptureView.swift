import SwiftUI

struct CaptureView: View {
    @ObservedObject var vm: CaptureViewModel
    /// User pressed ⌘↩ in input mode — kick off submit (manual or AI). Does NOT dismiss.
    let onSubmitInput: () -> Void
    /// User wants the window closed — ⎋ in input, or after a successful Review commit.
    let onDismiss: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // UX-03: brief "Saved" confirmation shown on both commit paths
            // (manual fast path and Review commit) just before the VM's
            // dismiss signal closes the window.
            if vm.showSavedConfirmation {
                SavedConfirmationBar()
            }

            // Provider-failure toast (plan 04-10, ROADMAP Phase 4 SC4).
            // Shown in the Review state after a failed extraction (and in
            // input if the user navigates back with the error still set).
            if let error = vm.lastError {
                ProviderErrorToast(
                    error: error,
                    fallbackAvailable: vm.fallbackAvailable,
                    onFallback: { Task { await vm.retryWithAppleFM() } },
                    onDismiss: { vm.lastError = nil })
            }

            // SC5: overlap confirm raised by the best-effort calendar pass.
            if let conflict = vm.pendingConflict {
                ConflictConfirmBar(
                    title: conflict.conflictTitle,
                    onCommitAnyway: { vm.resolveConflict(commitAnyway: true) },
                    onCancel: { vm.resolveConflict(commitAnyway: false) })
            }

            // Non-blocking degraded-calendar notice (denied access / write failure).
            if let notice = vm.calendarNotice {
                CalendarNoticeBar(notice: notice, onDismiss: { vm.calendarNotice = nil })
            }

            Group {
                switch vm.state {
                case .input:
                    inputView
                case .review(let tasks, _, _):
                    ReviewListView(
                        vm: vm,
                        tasks: tasks,
                        onCommit: {
                            // commitFromReview sets state back to .input on success
                            // and raises the saved/dismiss signals (UX-03); stays
                            // .review on disk error (with lastError set). Dismissal
                            // flows through the dismissRequested seam below.
                            vm.commitFromReview()
                        },
                        onCancel: { vm.returnToInput() }
                    )
                }
            }
        }
        // UX-03: single dismissal seam for BOTH commit paths. The VM raises
        // dismissRequested only on a successful commit; give the Saved toast a
        // beat on screen, then close via CaptureWindow's onDismiss closure.
        .onChange(of: vm.dismissRequested) { _, requested in
            guard requested else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                onDismiss()
            }
        }
    }

    // MARK: - Input view

    private var inputView: some View {
        VStack(spacing: 0) {
            // UX-08: a restored draft is announced, with a one-tap way to drop it.
            if vm.draftWasRestored {
                DraftRestoredBar(onClear: { vm.clearRestoredDraft() })
            }

            TextEditor(text: $vm.text)
                .font(.system(size: 14))
                .padding(12)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))
                // UX-01: freeze the text while extraction is in flight. Scoped to
                // the editor ONLY — the Esc key monitor attaches via .background
                // below and Esc-cancel must keep working mid-extraction.
                .disabled(vm.isExtracting)

            HStack(spacing: 8) {
                Text("⌘↩ submit  ·  ⎋ cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                // UX-08: clickable equivalents of the key bindings — Cancel
                // mirrors ⎋, Submit mirrors ⌘↩; both call the same code paths.
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Submit") { onSubmitInput() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 520, height: 280)
        // UX-01: extraction progress overlay (RESEARCH Pattern 3). Dimmed cover
        // while the AI call is in flight; Esc-cancel still works because the key
        // monitor is an NSEvent local monitor (not hit-tested through the overlay).
        .overlay {
            if vm.isExtracting {
                ZStack {
                    Color(NSColor.windowBackgroundColor).opacity(0.6)
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Extracting…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Extracting tasks")
            }
        }
        .onAppear {
            // Defer focus by one runloop tick: with LSUIElement = true and
            // .accessory activation policy, the window isn't quite settled
            // as key when .onAppear fires, so SwiftUI's @FocusState assignment
            // is dropped. Async dispatch lets the window become key first.
            DispatchQueue.main.async { focused = true }
        }
        .onSubmitKeyCommand { onSubmitInput() }
        .onCancelKeyCommand { onDismiss() }
    }
}

// MARK: - Saved confirmation bar (UX-03, plan 07.1-06)

/// Brief inline "Saved" confirmation shown after a successful commit on either
/// path (manual fast path or Review commit), just before the window closes via
/// the VM's dismiss signal. Same inline-bar idiom as the toasts below.
private struct SavedConfirmationBar: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Saved")
                .font(.system(size: 11))
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
        .accessibilityLabel("Saved")
    }
}

// MARK: - Draft restored bar (UX-08, plan 07.1-06)

/// Announces that a previous unsent draft was restored into the editor, with an
/// inline Clear control (`vm.clearRestoredDraft()`). Shows a fixed label only —
/// never the draft contents (threat register T-07.1-13).
private struct DraftRestoredBar: View {
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Draft restored")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Clear") { onClear() }
                .font(.system(size: 11))
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10))
    }
}

// MARK: - Provider-failure toast (plan 04-10)

/// Inline banner shown when extraction failed: human-readable error copy,
/// a one-tap "Use Apple FM instead" fallback (hidden when the active
/// provider already IS Apple FM), and a dismiss control.
private struct ProviderErrorToast: View {
    let error: AIProviderError
    let fallbackAvailable: Bool
    let onFallback: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 4)
            if fallbackAvailable {
                Button("Use Apple FM instead") { onFallback() }
                    .font(.system(size: 11))
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }

    /// UI-safe copy: `modelUnavailable.reason` and `guardrail.message` are
    /// human-readable per AIProvider's contract; `underlying.message` is
    /// debug-shape and must NOT be shown verbatim.
    private var message: String {
        switch error {
        case .modelUnavailable(let reason):
            return reason
        case .contextOverflow:
            return "The capture was too long for the selected AI provider."
        case .guardrail(let m):
            return m ?? "The AI provider declined to process this capture."
        case .underlying:
            return "The AI provider failed to process this capture."
        }
    }
}

// MARK: - Conflict confirm bar (Phase 5 SC5)

/// Inline "⚠️ overlaps with '<title>' — commit anyway?" affordance. Confirm commits both the
/// task and the event; cancel leaves the time-blocked task uncommitted (CONTEXT). The exact copy
/// matches the locked CONTEXT wording.
private struct ConflictConfirmBar: View {
    let title: String
    let onCommitAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("⚠️ overlaps with '\(title)' — commit anyway?")
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Commit anyway") { onCommitAnyway() }
                .font(.system(size: 11))
            Button("Cancel") { onCancel() }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }
}

// MARK: - Calendar notice bar (Phase 5 graceful degradation)

/// One-line non-blocking notice when the best-effort calendar work degraded (denied access or a
/// write failure). The task is already committed to disk; this only informs the user.
private struct CalendarNoticeBar: View {
    let notice: CalendarNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10))
    }

    private var message: String {
        switch notice {
        case .accessDenied:
            return "Calendar access not granted — enable in System Settings. Task saved without an event."
        case .writeFailed:
            return "Couldn't add the calendar event. Task saved; you can add it manually."
        }
    }
}

// Local key-binding helpers — wraps NSEvent monitoring at the view level.
private struct SubmitKeyModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.background(KeyMonitor(handler: { event in
            if event.modifierFlags.contains(.command), event.keyCode == 36 {
                action(); return true
            }
            return false
        }))
    }
}

private struct CancelKeyModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.background(KeyMonitor(handler: { event in
            if event.keyCode == 53 {   // Escape
                action(); return true
            }
            return false
        }))
    }
}

private struct KeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView { _KeyMonitorView(handler: handler) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class _KeyMonitorView: NSView {
    let handler: (NSEvent) -> Bool
    private nonisolated(unsafe) var monitor: Any?

    init(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Remove any prior monitor in case the view moved between windows.
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard let window = self.window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            return self.handler(event) ? nil : event
        }
    }

    nonisolated deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension View {
    func onSubmitKeyCommand(_ action: @escaping () -> Void) -> some View {
        modifier(SubmitKeyModifier(action: action))
    }
    func onCancelKeyCommand(_ action: @escaping () -> Void) -> some View {
        modifier(CancelKeyModifier(action: action))
    }
}
