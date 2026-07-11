import Combine
import CoreGraphics
import Foundation

/// The calendar-canvas view model (Phase 8 SC4 / CALX-04): composes the pure
/// `CanvasLayout` math over the menubar model's ALREADY-FETCHED data — today's
/// `calendarEvents` plus the day's tasks — into positioned render blocks, the
/// unscheduled-tasks rail, and drop-y → snapped-slot resolution.
///
/// Deliberately does NO I/O of its own (keeps it exhaustively unit-testable):
/// reads ride the injected `MenubarListModel` (same store, same calendar seam,
/// same `now()`), and writes go back through that model's `dropTask(id:atSlot:)`
/// so the canvas and the menubar dropdown always agree. Change propagation is a
/// plain `objectWillChange` forward — the canvas re-derives its computed
/// surface whenever the list model publishes.
@MainActor
final class CalendarCanvasModel: ObservableObject {
    /// Distinguishes calendar-event blocks from time-blocked-task blocks so the
    /// view can style them visually apart (plan must-have: distinct by kind).
    enum BlockKind: Equatable {
        case event
        case task
    }

    /// One positioned rectangle on the time axis: y/height are precomputed via
    /// `CanvasLayout` so the view is pure rendering (no ad-hoc coordinate→time
    /// math outside the tested helpers, T-8-11).
    struct Block: Identifiable, Equatable {
        let id: String
        let kind: BlockKind
        let title: String
        let start: Date
        let end: Date
        let y: CGFloat
        let height: CGFloat

        /// Horizontal packing for overlapping blocks (#2): `column` is this block's
        /// 0-based slot and `columnCount` its cluster's total, so the view renders it
        /// at `width/columnCount` offset by `column`. Default `0`/`1` = full width
        /// (a block that overlaps nothing). Computed in `blocks` via `CanvasLayout.columns`.
        var column: Int = 0
        var columnCount: Int = 1

        /// The BARE task id for a `.task` block (nil for `.event`), recovered by
        /// stripping the `"task-"` namespace prefix `blocks` applies. This is the
        /// id `MenubarListModel.dropTask(id:atSlot:)` resolves against — the same
        /// bare id the rail drags — so a placed task block can be re-dragged to
        /// MOVE it (CALX-01) without namespacing leaking into the drop path.
        var taskID: String? {
            kind == .task ? String(id.dropFirst("task-".count)) : nil
        }
    }

    /// The SHARED menubar model (store + calendar seam + now() + timezone).
    /// Exposed so the canvas view can call `dropTask`/`resolveDropConflict`
    /// and observe `pendingDropConflict` on the same instance the dropdown uses.
    let list: MenubarListModel

    /// Vertical scale of the axis (RESEARCH A2: 60 — Claude discretion).
    let pixelsPerHour: CGFloat
    /// Drop-snap granularity in minutes (RESEARCH A2: 15 — Claude discretion).
    let snapMinutes: Int

    private var cancellable: AnyCancellable?

    init(list: MenubarListModel,
         pixelsPerHour: CGFloat = CanvasLayout.defaultPixelsPerHour,
         snapMinutes: Int = CanvasLayout.defaultSnapMinutes) {
        self.list = list
        self.pixelsPerHour = pixelsPerHour
        self.snapMinutes = snapMinutes
        // Forward the list model's publishes: every reload (drop write-back,
        // midnight timer, popover open) re-derives blocks/rail in the canvas.
        cancellable = list.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// The axis origin: startOfDay(now()) in the MODEL timezone — the same
    /// tz-pinned instant the menubar partitions with, so positions are
    /// tz-correct (behavior: dayStart derivation).
    var dayStart: Date { list.startOfToday }

    /// End of the axis: the NEXT day's start. On a DST-transition day this is 23 or
    /// 25 wall-clock hours after `dayStart` — the axis spans the day's REAL length.
    var dayEnd: Date {
        DailyFile.calendar(timezone: list.timezone)
            .date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 3600)
    }

    /// Total axis height: the day's ACTUAL physical span (24h normally, 23h/25h on
    /// DST days) at the vertical scale — a fixed 24h axis clipped the last hour of
    /// a fall-back day.
    var axisHeight: CGFloat {
        CGFloat(dayEnd.timeIntervalSince(dayStart) / 3600) * pixelsPerHour
    }

    /// One hour gridline: `idx` is the unique loop position (0…24, the ForEach id
    /// and scroll anchor), `label` the wall-clock text, `y` the PHYSICAL position.
    struct HourMark: Identifiable, Equatable {
        let idx: Int
        let label: String
        let y: CGFloat
        var id: Int { idx }
    }

    /// Wall-clock hour gridlines derived from REAL instants (never `hour × scale`):
    /// on a 25h fall-back day "09:00" sits 10 physical hours down the axis, exactly
    /// where the (physical) drop-slot math puts a 09:00 drop — fixed offsets made
    /// the labels and the stored times disagree by an hour after the transition.
    /// A nonexistent hour (spring-forward 02:00) yields no line; the closing "00:00"
    /// renders at `dayEnd`.
    var hourMarks: [HourMark] {
        let cal = DailyFile.calendar(timezone: list.timezone)
        var marks: [HourMark] = []
        for h in 0...24 {
            let instant: Date? = h == 24
                ? dayEnd
                : cal.date(bySettingHour: h, minute: 0, second: 0, of: dayStart)
            guard let instant, instant >= dayStart, instant <= dayEnd else { continue }
            marks.append(HourMark(
                idx: h,
                label: String(format: "%02d:00", h % 24),
                y: CanvasLayout.y(for: instant, dayStart: dayStart,
                                  pixelsPerHour: pixelsPerHour)))
        }
        return marks
    }

    /// The current-time indicator's y, nil when `instant` is outside today's axis.
    func nowY(at instant: Date) -> CGFloat? {
        guard instant >= dayStart, instant <= dayEnd else { return nil }
        return CanvasLayout.y(for: instant, dayStart: dayStart, pixelsPerHour: pixelsPerHour)
    }

    /// The hour anchor the canvas scrolls to on open: one hour above "now" so the
    /// current slot sits in view with context (was a fixed `hour-7` regardless of
    /// the actual time of day).
    func scrollAnchorHour(at instant: Date) -> Int {
        let cal = DailyFile.calendar(timezone: list.timezone)
        return max(0, cal.component(.hour, from: instant) - 1)
    }

    /// Today's positioned blocks: calendar events + time-blocked tasks, each
    /// carrying a precomputed `CanvasLayout` y/height, sorted by y for a stable
    /// render order. Ids are namespaced per kind so an event id can never
    /// collide with a task id inside one `ForEach`.
    var blocks: [Block] {
        let events = list.visibleCalendarEvents.map { event in
            Block(id: "event-\(event.id)", kind: .event, title: event.title,
                  start: event.start, end: event.end,
                  y: CanvasLayout.y(for: event.start, dayStart: dayStart,
                                    pixelsPerHour: pixelsPerHour),
                  height: CanvasLayout.height(start: event.start, end: event.end,
                                              pixelsPerHour: pixelsPerHour))
        }
        let tasks = list.todayTasks
            .compactMap { task -> Block? in
                guard let tb = task.timeBlock else { return nil }
                return Block(id: "task-\(task.id)", kind: .task, title: task.text,
                             start: tb.start, end: tb.end,
                             y: CanvasLayout.y(for: tb.start, dayStart: dayStart,
                                               pixelsPerHour: pixelsPerHour),
                             height: CanvasLayout.height(start: tb.start, end: tb.end,
                                                         pixelsPerHour: pixelsPerHour))
            }
        // Sort by y (start), then pack overlapping blocks into side-by-side columns
        // (#2) — events and tasks share ONE packing so a task never hides behind an
        // event. Non-overlapping blocks stay full width (column 0 of 1).
        let sorted = (events + tasks).sorted { $0.y < $1.y }
        let cols = CanvasLayout.columns(for: sorted.map { (start: $0.start, end: $0.end) })
        return zip(sorted, cols).map { block, layout in
            var placed = block
            placed.column = layout.column
            placed.columnCount = layout.columnCount
            return placed
        }
    }

    /// The draggable unscheduled rail: the menubar model's visible, not-done,
    /// `timeBlock == nil` tasks (plan 04's `unscheduledTasks` — leftovers stay
    /// draggable, future-snoozed tasks never appear).
    var rail: [Todo] { list.unscheduledTasks }

    /// Resolves a drop y on the axis to a snapped slot `Date` — pure delegation
    /// to the tested `CanvasLayout.slot` with the model's own dayStart/pph/snap
    /// (T-8-11: no ad-hoc coordinate→time math anywhere else).
    func slot(atY y: CGFloat) -> Date {
        CanvasLayout.slot(atY: y, dayStart: dayStart,
                          pixelsPerHour: pixelsPerHour, snapMinutes: snapMinutes)
    }
}
