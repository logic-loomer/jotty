import Foundation

/// One searchable ⌘K palette result — the corpus unit CommandBarModel (09-04)
/// ranks with FuzzyScorer and routes on Enter (CMDB-02).
///
/// The derivations below are PINNED (tests assert exact values) so 09-04's
/// ranking tests are deterministic:
/// - `id` (stable String, SwiftUI identity + selection tracking + tiebreak):
///   `action:<Action.rawValue>` | `today:<todo.id>` | `inbox:<item.id>` |
///   `earlier:<todo.id>:<yyyy-MM-dd>` | `day:<yyyy-MM-dd>`
/// - `searchText` (what FuzzyScorer sees): action label; task text; inbox title
///   with the SuggestedSection rawText fallback; day files match on BOTH the raw
///   `yyyy-MM-dd` name and an `en_US_POSIX` "EEE MMM d yyyy" label, so "2026-06"
///   AND "jun" hit and no test ever depends on machine locale.
/// - `recency` (section-internal ranking key): todayTask → createdAt;
///   earlierTask/dayFile → their ORIGIN day; action/inbox → nil.
///
/// Day strings format in `TimeZone.current`, matching how every production Store
/// is constructed (`Store(folder:timezone: .current)`, AppDelegate) — the same
/// zone `buildHistorical` callers pass, so the id round-trips the on-disk file
/// name exactly. The formatter builder is the shared POSIX/Gregorian-pinned
/// `DailyFile.dayFormatter` — never a hand-rolled `yyyy-MM-dd` (WR-05 idiom).
enum CommandItem: Identifiable, Equatable {
    case action(CommandAction)
    case todayTask(Todo)
    case inbox(InboxItem)
    case earlierTask(Todo, day: Date)
    case dayFile(day: Date, taskCount: Int)

    var id: String {
        switch self {
        case .action(let a): return "action:\(a.action.rawValue)"
        case .todayTask(let t): return "today:\(t.id)"
        case .inbox(let i): return "inbox:\(i.id)"
        case .earlierTask(let t, let day): return "earlier:\(t.id):\(Self.dayKey(day))"
        case .dayFile(let day, _): return "day:\(Self.dayKey(day))"
        }
    }

    var searchText: String {
        switch self {
        case .action(let a): return a.label
        case .todayTask(let t): return t.text
        case .inbox(let i): return i.title.isEmpty ? i.rawText : i.title
        case .earlierTask(let t, _): return t.text
        case .dayFile(let day, _): return "\(Self.dayKey(day)) \(Self.dayLabel(day))"
        }
    }

    var recency: Date? {
        switch self {
        case .action, .inbox: return nil
        case .todayTask(let t): return t.createdAt
        case .earlierTask(_, let day): return day
        case .dayFile(let day, _): return day
        }
    }

    /// Cached formatters (review IN-02): `rescore()` evaluates `searchText` for
    /// every corpus item on EVERY keystroke — constructing a formatter per call
    /// (well over a thousand per keystroke at multi-year scale) undercut the
    /// documented sub-ms re-rank budget. DateFormatter is `Sendable`, and both are
    /// fully configured at init and never mutated afterwards, so a plain `static let`
    /// is concurrency-safe — no `nonisolated(unsafe)` needed.
    private static let dayKeyFormatter =
        DailyFile.dayFormatter(timezone: .current)
    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "EEE MMM d yyyy"
        f.timeZone = .current
        return f
    }()

    /// The machine day key ("2026-06-15") — the raw file-name form.
    private static func dayKey(_ day: Date) -> String {
        dayKeyFormatter.string(from: day)
    }

    /// The human day label ("Mon Jun 15 2026"). Locale/calendar pinned exactly
    /// like `DailyFile.dayFormatter` so the label — and every test asserting it —
    /// is independent of the machine's region settings.
    private static func dayLabel(_ day: Date) -> String {
        dayLabelFormatter.string(from: day)
    }
}

/// The two ⌘K corpus builders (CMDB-02). Queries never touch these — the model
/// re-ranks the built corpus in memory on each keystroke; per-open rebuild is the
/// locked design (no persistent index).
enum CommandBarIndex {

    /// Pure, order-preserving mapping of the already-in-memory corpus: settings
    /// actions (registry order) + today's tasks (leftovers+today partition order,
    /// already snooze-filtered and now()-anchored, CR-03) + fetched inbox
    /// suggestions (service order). Zero I/O, zero network by construction.
    static func buildImmediate(actions: [CommandAction], today: [Todo],
                               inbox: [InboxItem]) -> [CommandItem] {
        actions.map(CommandItem.action)
            + today.map(CommandItem.todayTask)
            + inbox.map { CommandItem.inbox($0) }
    }

    /// Enumerates every historical day file and yields `.earlierTask` items (with
    /// origin day) plus one `.dayFile` per day, newest day first.
    ///
    /// Rules (RESEARCH §Integration Seams 3 + Pitfall 5):
    /// - Constructs a PRIVATE `Store(folder:timezone:)` — a cheap value wrapper —
    ///   so a live-swapped outer store is never captured (Pitfall 9); callers pass
    ///   the folder/timezone they resolved at open time.
    /// - Excludes the day whose `DailyFile.dayFormatter` string equals `today`'s:
    ///   today's tasks come LIVE from the menubar partitions (CR-03), never disk.
    /// - SKIPS tasks with `rolledTo != nil`: a rolled-forward task exists twice on
    ///   disk (origin line keeps rolled_to:, live copy sits in today's file);
    ///   indexing both would duplicate every leftover (Pitfall 5). Recurrence
    ///   templates (recur: set) ARE included — real user lines, origin-dated.
    /// - `taskCount` counts survivors (non-rolled) only.
    /// - Fail-soft (Pattern 3): a missing folder yields []; a read failure logs
    ///   and skips that day, never fatal. (`Store.readDoc` additionally degrades
    ///   unparseable content to an empty doc, so a corrupt day surfaces as a
    ///   taskCount-0 day file — still openable so the user can find and fix it.)
    ///
    /// `nonisolated` so 09-04 can run this in a `Task.detached` off the main
    /// actor and hop the results back (Todo/InboxItem are Sendable-safe values).
    nonisolated static func buildHistorical(folder: URL, timezone: TimeZone,
                                            excludingDay today: Date) -> [CommandItem] {
        let store = Store(folder: folder, timezone: timezone)
        let formatter = DailyFile.dayFormatter(timezone: timezone)
        let todayKey = formatter.string(from: today)

        // Strictly BEFORE today (review IN-03): `allDayDates()` documents that
        // era-shifted legacy filenames (e.g. `2569-07-03.md`) parse as far-future
        // days and that consumers filter `< today` — otherwise such a file would
        // index as a top-ranked "Earlier" item with future recency. String
        // comparison is safe given the fixed `yyyy-MM-dd` format.
        let days = store.allDayDates()
            .filter { formatter.string(from: $0) < todayKey }
            .sorted(by: >)   // newest day first

        var items: [CommandItem] = []
        for day in days {
            let doc: MarkdownDoc
            do {
                doc = try store.readDoc(on: day)
            } catch {
                NSLog("[Jotty] command bar index: skipping day \(formatter.string(from: day)): \(error.localizedDescription)")
                continue
            }
            let surviving = doc.tasks.filter { $0.rolledTo == nil }
            for todo in surviving {
                items.append(.earlierTask(todo, day: day))
            }
            items.append(.dayFile(day: day, taskCount: surviving.count))
        }
        return items
    }
}
