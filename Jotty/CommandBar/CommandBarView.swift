import AppKit
import SwiftUI

/// The THIN ⌘K bar view (09-UI-SPEC design contract, implemented verbatim).
///
/// Zero logic lives here: every key forwards to `CommandBarModel`
/// (`moveSelection` / `activateSelection` / `activate(visibleRow:)`); the only
/// view-local derivations are per-kind glyph/badge/label mappings reading
/// `CommandItem`. There is deliberately NO ⌘K handling anywhere in this view —
/// toggle-closed lives ONLY in the global hotkey handler (Pitfall 10: a local
/// ⌘K equivalent + the Carbon hotkey would double-toggle after migration).
struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel
    /// Esc → close, injected by CommandBarPanelController.
    let onClose: () -> Void
    /// Content-height report → the controller resizes the panel to hug content.
    var onHeightChange: ((CGFloat) -> Void)?

    @FocusState private var searchFocused: Bool
    @State private var hoveredID: String?
    @State private var resultsHeight: CGFloat = 0
    /// A11Y-02: fixed glyph columns scale with the user's text preference.
    @ScaledMetric(relativeTo: .title2) private var searchGlyphWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var rowGlyphWidth: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Results area cap: ~8 visible rows before internal scroll (UI-SPEC).
    private let maxResultsHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            if !model.query.isEmpty {
                if model.sections.isEmpty {
                    Divider()
                    noResults
                } else {
                    Divider()
                    resultsList
                }
            }
            // Empty query: search row ONLY — no divider, no list (UI-SPEC).
        }
        .frame(width: 640, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
        // Height animates on result changes; Reduce Motion snaps (UI-SPEC A11y).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                   value: model.visibleRows.map(\.id))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            onHeightChange?(height)
        }
        .background(CommandBarKeyMonitor(handler: handleKey))
        .onAppear {
            // Focus nudge: @FocusState inside NSHostingController doesn't take
            // on first render (in-repo workaround, MenubarListView rename field).
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.openToken) {
            // Retained controller: onAppear may not re-run on later shows — the
            // per-open token IS the re-focus signal.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.query) {
            announceResultCount()
        }
    }

    // MARK: - Search row (UI-SPEC §Search Field)

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: searchGlyphWidth)
            TextField("", text: $model.query,
                      prompt: Text("Search tasks, days, actions…"))
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($searchFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - No-results state (UI-SPEC §Empty & No-Results)

    private var noResults: some View {
        Text("No results for \"\(model.query)\"")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    /// VoiceOver: result count announced on query change, same cadence as the
    /// scorer (UI-SPEC §Accessibility).
    private func announceResultCount() {
        guard !model.query.isEmpty else { return }
        let count = model.visibleRows.count
        let message = count == 0 ? "No results" : "\(count) results"
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Results list (UI-SPEC §Results List)

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Flat row index across sections drives the ⌘1-9 hints —
                    // matches the model's activate(visibleRow:) numbering space.
                    let flatIDs = model.visibleRows.map(\.id)
                    ForEach(model.sections) { section in
                        sectionHeader(section.kind)
                        ForEach(section.items) { item in
                            // `?? -1` (review IN-04): defensively unreachable
                            // (every rendered item is in visibleRows), but if the
                            // identity assumption ever broke, `.max` would make
                            // the tap's `flatIndex + 1` an overflow TRAP — while
                            // -1 + 1 == 0 is already a no-op in activate(visibleRow:).
                            row(item, flatIndex: flatIDs.firstIndex(of: item.id) ?? -1)
                        }
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    resultsHeight = height
                }
            }
            .frame(height: min(resultsHeight, maxResultsHeight))
            .onChange(of: model.selectedID) { _, newID in
                if let newID { proxy.scrollTo(newID) }
            }
        }
    }

    /// Menubar section-header idiom: not selectable, skipped by ↑↓ (headers are
    /// never in `visibleRows`), `.isHeader` for the VoiceOver rotor.
    private func sectionHeader(_ kind: SectionKind) -> some View {
        Text(kind.rawValue)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Row (UI-SPEC §Row Anatomy)

    private func row(_ item: CommandItem, flatIndex: Int) -> some View {
        let selected = model.selectedID == item.id
        return HStack(spacing: 8) {
            Image(systemName: glyph(for: item))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: rowGlyphWidth)
            Text(emphasizedTitle(for: item))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            inlineMetadata(for: item)
            Spacer(minLength: 4)
            trailingBadge(for: item)
            if flatIndex < 9 {
                Text("⌘\(flatIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected
                      ? Color.accentColor.opacity(0.18)
                      : (hoveredID == item.id ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        // Click = select + act; hover NEVER moves the keyboard selection.
        .onTapGesture { model.activate(visibleRow: flatIndex + 1) }
        .onHover { inside in
            if inside { hoveredID = item.id }
            else if hoveredID == item.id { hoveredID = nil }
        }
        .id(item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: item))
        .accessibilityHint(flatIndex < 9
                           ? "Press Return or Command \(flatIndex + 1) to select"
                           : "Press Return to select")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Key routing (UI-SPEC §Keyboard Model — window-scoped local monitor)

    /// Every handled key forwards to the model; everything else returns to the
    /// TextField (typing always flows to the field). NO ⌘K here (Pitfall 10).
    private func handleKey(_ event: NSEvent) -> Bool {
        // ⌘1-9 → activate the n-th flat visible row (checked before the
        // keyCode switch so digit keys WITHOUT ⌘ still type into the field).
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let n = Int(chars), (1...9).contains(n) {
            model.activate(visibleRow: n)
            return true
        }
        switch event.keyCode {
        case 126: model.moveSelection(-1); return true   // ↑
        case 125: model.moveSelection(1); return true    // ↓
        case 36:  model.activateSelection(); return true // Return
        case 53:  onClose(); return true                 // Esc
        case 48:  return true // Tab: swallow — focus never leaves the field
        default:  return false
        }
    }
}

// MARK: - Per-kind derivations (presentation only — reads CommandItem)

private extension CommandBarView {

    func glyph(for item: CommandItem) -> String {
        switch item {
        case .action(let a): return a.symbol
        case .todayTask(let t): return t.done ? "checkmark.square" : "square"
        case .inbox(let i): return InboxSourceGlyph.glyph(for: i.sourceID)
        case .earlierTask: return "square"
        case .dayFile: return "doc.text"
        }
    }

    func title(for item: CommandItem) -> String {
        switch item {
        case .action(let a): return a.label
        case .todayTask(let t): return t.text
        case .inbox(let i): return i.title.isEmpty ? i.rawText : i.title
        case .earlierTask(let t, _, _): return t.text
        case .dayFile(let day, _, _, _): return Self.dayTitle(day)
        }
    }

    /// Fuzzy-match emphasis: matched characters render semibold via
    /// AttributedString — weight change ONLY, no color (UI-SPEC §Row Anatomy).
    /// Re-runs the scorer's greedy folded subsequence walk per character to
    /// find matched positions (FuzzyScorer returns a score, not indices).
    func emphasizedTitle(for item: CommandItem) -> AttributedString {
        let text = title(for: item)
        var attributed = AttributedString(text)
        let query = model.query
        guard !query.isEmpty else { return attributed }

        let fold: (Character) -> String = {
            String($0).folding(options: [.caseInsensitive, .diacriticInsensitive],
                               locale: nil)
        }
        var queryChars = query.map(fold)[...]
        var position = attributed.startIndex
        for ch in text {
            guard let expected = queryChars.first else { break }
            let next = attributed.index(afterCharacter: position)
            if fold(ch) == expected {
                attributed[position..<next].font = .callout.weight(.semibold)
                queryChars = queryChars.dropFirst()
            }
            position = next
        }
        return attributed
    }

    @ViewBuilder
    func inlineMetadata(for item: CommandItem) -> some View {
        if case .dayFile(_, let taskCount, _, _) = item, taskCount > 0 {
            Text("· \(taskCount) tasks")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func trailingBadge(for item: CommandItem) -> some View {
        switch item {
        case .todayTask(let t):
            if let block = t.timeBlock {
                // #3: shared formatter so this HH:mm pill matches the menubar list.
                Text(TaskBadge.timeBlockPill(block, timezone: .current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        case .earlierTask(_, let day, _):
            Text(Self.originLabel(day))
                .font(.caption)
                .foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    func accessibilityLabel(for item: CommandItem) -> String {
        switch item {
        case .action(let a):
            return "Run action: \(a.label)"
        case .todayTask(let t):
            var label = "Today's task: \(t.text), \(t.done ? "done" : "not done")"
            if let block = t.timeBlock {
                label += ", scheduled \(TaskBadge.timeBlockPill(block, timezone: .current))"
            }
            return label
        case .inbox(let i):
            return "Inbox suggestion from \(i.sourceID): \(i.title.isEmpty ? i.rawText : i.title)"
        case .earlierTask(let t, let day, _):
            return "Earlier task from \(Self.originLabel(day)): \(t.text)"
        case .dayFile(let day, _, _, _):
            return "Day file: \(Self.dayTitle(day))"
        }
    }

    // MARK: Date/time formatting (07.1 origin-date idiom)

    // Time-block start formatting moved to the shared `TaskBadge.timeBlockPill` (#3).

    /// Earlier origin date: "MMM d", adding ", yyyy" when not the current year.
    static func originLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = isCurrentYear(day) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: day)
    }

    /// Day-file title: "EEE MMM d", adding ", yyyy" when not the current year.
    static func dayTitle(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = isCurrentYear(day) ? "EEE MMM d" : "EEE MMM d, yyyy"
        return f.string(from: day)
    }

    static func isCurrentYear(_ day: Date) -> Bool {
        Calendar.current.component(.year, from: day)
            == Calendar.current.component(.year, from: Date())
    }
}

// MARK: - Window-scoped key monitor (CaptureView KeyMonitor idiom)

/// Phase 9 review WR-03: while an input-method composition is in progress
/// (Japanese/Chinese/Korean marked text), Return must confirm the composition,
/// ↑↓ must navigate the candidate window, and Esc must cancel it — the palette
/// monitor must NOT swallow those keys. Pure decision seam so the bypass rule
/// is unit-testable; the live monitor feeds it `NSTextInputContext.current?.client`.
/// The full IME interaction (candidate window in the real panel) stays HUMAN-UAT.
enum CommandBarIMEGuard {
    static func shouldDeferToInputMethod(client: (any NSTextInputClient)?) -> Bool {
        client?.hasMarkedText() ?? false
    }
}

/// Mirror of the CaptureView `KeyMonitor` NSViewRepresentable: a local NSEvent
/// keyDown monitor scoped to THIS view's window — the AppKit-reliable route for
/// panel keys (resolves RESEARCH A2/A3; pinned by UI-SPEC §Keyboard Model).
private struct CommandBarKeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView { MonitorView(handler: handler) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class MonitorView: NSView {
        let handler: (NSEvent) -> Bool
        private nonisolated(unsafe) var monitor: Any?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let window = self.window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                // WR-03: an active IME composition owns Return/↑↓/Esc — pass
                // the event through to the field editor's input context.
                if CommandBarIMEGuard.shouldDeferToInputMethod(
                    client: NSTextInputContext.current?.client) { return event }
                return self.handler(event) ? nil : event
            }
        }

        nonisolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
