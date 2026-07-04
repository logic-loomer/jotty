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

    /// Today's positioned blocks: calendar events + time-blocked tasks, each
    /// carrying a precomputed `CanvasLayout` y/height, sorted by y for a stable
    /// render order. Ids are namespaced per kind so an event id can never
    /// collide with a task id inside one `ForEach`.
    var blocks: [Block] {
        let events = list.calendarEvents.map { event in
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
        return (events + tasks).sorted { $0.y < $1.y }
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
