import SwiftUI

struct CaptureView: View {
    @ObservedObject var vm: CaptureViewModel
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $vm.text)
                .font(.system(size: 14))
                .padding(12)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))

            HStack {
                Spacer()
                Text("⌘↩ submit  ·  ⎋ cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 520, height: 280)
        .onAppear {
            // Defer focus by one runloop tick: with LSUIElement = true and
            // .accessory activation policy, the window isn't quite settled
            // as key when .onAppear fires, so SwiftUI's @FocusState assignment
            // is dropped. Async dispatch lets the window become key first.
            DispatchQueue.main.async { focused = true }
        }
        .onSubmitKeyCommand { onSubmit() }
        .onCancelKeyCommand { onCancel() }
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
