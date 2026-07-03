import AppKit
import Foundation

/// One rendered palette section: a fixed `SectionKind` plus its ranked, capped
/// items. Identity is the kind's raw value (sections are singletons per open).
struct CommandSection: Identifiable {
    let kind: SectionKind
    let items: [CommandItem]
    var id: String { kind.rawValue }
}

/// The five palette sections in their LOCKED display order (CONTEXT):
/// Actions → Today → Inbox → Earlier → Days. `allCases` order IS the display
/// order — `rescore()` iterates it to assemble sections.
enum SectionKind: String, CaseIterable {
    case actions = "Actions", today = "Today", inbox = "Inbox",
         earlier = "Earlier", days = "Days"
}

/// The ⌘K palette's entire brain, headless (CMDB-01/02, SC2/SC3/SC4):
/// per-open corpus build, query→sections ranking, id-tracked selection, and
/// Enter routing over EXISTING seams only. Mirrors CalendarCanvasModel's
/// shared-model composition: composes over the injected `MenubarListModel`
/// (same store, same partitions, same inbox service) and does no I/O of its
/// own beyond the off-main historical build.
///
/// The view (09-05) stays thin: it renders `sections`, forwards keys to
/// `moveSelection`/`activateSelection`/`activate(visibleRow:)`, and never
/// contains logic.
@MainActor
final class CommandBarModel: ObservableObject {

    /// The SHARED menubar model — today partitions, inbox suggestions, the
    /// live-swappable store (Pitfall 9), and the acceptSuggestion write path.
    let list: MenubarListModel
    /// Settings-action Enter routes ONLY through this (IN-01 contract).
    let dispatcher: ActionDispatcher
    private let actions: [CommandAction]
    private let openURL: (URL) -> Void
    private let now: () -> Date

    /// Enter on a TODAY task → open the menubar dropdown highlighting this
    /// task id. AppDelegate wires it to `MenubarController.showPopover` (09-05).
    var onOpenMenubar: ((String) -> Void)?
    /// Panel close request — ALWAYS called BEFORE any Enter effect (Pitfall 8:
    /// the transient popover must not open while the panel is still key).
    var onRequestClose: (() -> Void)?

    /// Live query text. Re-scores SYNCHRONOUSLY on every change — no debounce.
    /// Discretion note: UI-SPEC offers an optional 80 ms debounce, but scoring
    /// the in-memory corpus is sub-ms at this scale (RESEARCH §Fuzzy Scorer
    /// benchmark margin), and synchronous wins for determinism + testability.
    @Published var query: String = "" {
        didSet { rescore() }
    }
    @Published private(set) var sections: [CommandSection] = []
    /// Selection tracked by CommandItem.id (never index): survives a re-score
    /// while the id stays visible; resets to the first row when it disappears.
    @Published private(set) var selectedID: String?
    /// Fresh UUID per `prepareForOpen()` — the view observes it to re-focus
    /// the search field on every show (retained-controller focus nudge).
    @Published private(set) var openToken = UUID()

    /// Per-open corpus. `immediate` is built synchronously at open (actions +
    /// live today partitions + fetched inbox suggestions); `historical` arrives
    /// via `merge(historical:generation:)` from the detached build.
    private var immediate: [CommandItem] = []
    private var historical: [CommandItem] = []
    /// Open-generation counter: bumped by every `prepareForOpen()` so a stale
    /// historical build can never land after close/reopen. Internal (not
    /// private) so tests seed/guard through the same door the build uses.
    private(set) var generation = 0

    init(list: MenubarListModel,
         dispatcher: ActionDispatcher,
         actions: [CommandAction] = CommandActionRegistry.all,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = Date.init) {
        self.list = list
        self.dispatcher = dispatcher
        self.actions = actions
        self.openURL = openURL
        self.now = now
    }

    /// Flat, capped row list in section order — the ⌘1-9 / ↑↓ navigation space.
    var visibleRows: [CommandItem] { sections.flatMap(\.items) }

    // MARK: - Per-open build

    /// Resets the palette and rebuilds the corpus for THIS open. Resolves
    /// `list.store` and `now()` LIVE (Pitfall 9 / CR-03): a store swapped in
    /// Settings or a midnight crossing must never leave the palette anchored
    /// to launch-time state. Immediate sections (actions/today/inbox) build
    /// synchronously; the historical corpus builds off-main and merges only
    /// while this open's generation is still current.
    ///
    /// Zero-network by construction: inbox suggestions are read from memory —
    /// `refresh()` is NEVER called here (locked decision).
    func prepareForOpen() {
        generation += 1
        query = ""          // didSet → rescore() → sections = []
        selectedID = nil
        openToken = UUID()

        immediate = CommandBarIndex.buildImmediate(
            actions: actions,
            today: list.leftovers + list.todayTasks,
            inbox: list.inboxService?.suggestions ?? [])
        historical = []
        rescore()

        // Capture folder/timezone/today NOW (activation-time values belong to
        // THIS open); the detached parse hops back through merge(), which
        // drops the result if the palette was closed/reopened meanwhile.
        let folder = list.store.folder
        let timezone = list.store.timezone
        let today = now()
        let capturedGeneration = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = CommandBarIndex.buildHistorical(
                folder: folder, timezone: timezone, excludingDay: today)
            await self?.merge(historical: items, generation: capturedGeneration)
        }
    }

    /// Appends the off-main historical build to the corpus and re-scores,
    /// keeping the current query/selection semantics. A stale generation —
    /// a build that outlived its open — is dropped SILENTLY (the tested
    /// contract; RESEARCH §Performance generation guard).
    func merge(historical items: [CommandItem], generation buildGeneration: Int) {
        guard buildGeneration == generation else { return }
        historical += items
        rescore()
    }

    // MARK: - Ranking (locked caps/order)

    private func sectionKind(of item: CommandItem) -> SectionKind {
        switch item {
        case .action: return .actions
        case .todayTask: return .today
        case .inbox: return .inbox
        case .earlierTask: return .earlier
        case .dayFile: return .days
        }
    }

    /// Synchronous re-rank of the in-memory corpus (never touches disk).
    /// Empty query → NO sections (UI-SPEC Empty & No-Results pin: the bar is a
    /// single quiet row until the user types). Non-empty: FuzzyScorer per item
    /// (nil → drop); within a section (score desc, recency desc with nil
    /// LAST, id asc); cap 8/section; fixed SectionKind order; hide empty
    /// sections; truncate to 40 overall dropping from the TAIL of the last
    /// sections, preserving order.
    private func rescore() {
        guard !query.isEmpty else {
            sections = []
            selectedID = nil
            return
        }

        var buckets: [SectionKind: [(item: CommandItem, score: Int)]] = [:]
        for item in immediate + historical {
            guard let score = FuzzyScorer.score(query: query, candidate: item.searchText)
            else { continue }
            buckets[sectionKind(of: item), default: []].append((item, score))
        }

        var built: [CommandSection] = []
        for kind in SectionKind.allCases {
            guard var scored = buckets[kind], !scored.isEmpty else { continue }
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                switch (a.item.recency, b.item.recency) {
                case let (x?, y?) where x != y: return x > y
                case (.some, .none): return true    // nil recency sorts LAST
                case (.none, .some): return false
                default: return a.item.id < b.item.id
                }
            }
            built.append(CommandSection(kind: kind, items: scored.prefix(8).map(\.item)))
        }

        // Overall cap 40: drop from the tail of the LAST sections. (With 5
        // sections × cap 8 the total tops out at exactly 40, so this loop is
        // a defensive invariant — kept because the caps are locked separately.)
        var total = built.reduce(0) { $0 + $1.items.count }
        var index = built.count - 1
        while total > 40 && index >= 0 {
            let drop = min(total - 40, built[index].items.count)
            built[index] = CommandSection(
                kind: built[index].kind,
                items: Array(built[index].items.dropLast(drop)))
            total -= drop
            index -= 1
        }
        built.removeAll { $0.items.isEmpty }
        sections = built

        // Selection: keep the id if still visible, else default to first.
        let rows = visibleRows
        if let selected = selectedID, rows.contains(where: { $0.id == selected }) {
            return
        }
        selectedID = rows.first?.id
    }

    // MARK: - Selection (SC4 keyboard semantics)

    /// ↑↓: moves the selection ±1 over the flat `visibleRows`, CLAMPED at both
    /// ends (no wrap — Spotlight parity). No rows → no-op.
    func moveSelection(_ delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let selected = selectedID,
              let current = rows.firstIndex(where: { $0.id == selected }) else {
            selectedID = rows.first?.id
            return
        }
        let clamped = min(max(current + delta, 0), rows.count - 1)
        selectedID = rows[clamped].id
    }

    /// ⌘1-9: selects then activates the n-th FLAT visible row (1-based, section
    /// order — matches the on-screen numbering badges). Out-of-range → no-op.
    func activate(visibleRow n: Int) {
        let rows = visibleRows
        guard n >= 1, n <= rows.count else { return }
        selectedID = rows[n - 1].id
        activateSelection()
    }

    /// Enter: routes the selected row per its kind (09-04 Task 2). No rows or
    /// no selection → no-op (no close, no effect).
    func activateSelection() {
        // Task 2 wires the per-kind Enter routing.
    }
}
