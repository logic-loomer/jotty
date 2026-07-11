import AppKit
import SwiftUI

/// The calendar canvas window (Phase 8 SC4 / CALX-04): a vertical time-of-day
/// axis for today rendering calendar events + time-blocked tasks at their
/// `CanvasLayout` positions, plus a draggable unscheduled-tasks rail. Dragging
/// a rail task onto the axis resolves the drop y to a snapped slot Date
/// (`CalendarCanvasModel.slot(atY:)` → `CanvasLayout.slot`) and calls the
/// plan-04 `dropTask(id:atSlot:)` — the visible half of CALX-01.
///
/// OPTIONAL surface (CONTEXT): the menubar dropdown remains the default; this
/// is an alternative view opened on demand. A separate `NSWindow` (RESEARCH A3)
/// rather than a popover — popover drag/focus is fragile.
struct CalendarCanvasView: View {
    /// Forwards the list model's publishes, so every reload (drop write-back,
    /// midnight timer, popover open) re-derives blocks + rail here too.
    @ObservedObject var model: CalendarCanvasModel

    /// True while a drag hovers the axis (subtle targeting highlight).
    @State private var dropTargeted = false

    /// Width of the hour-label gutter on the left of the axis.
    private static let hourLabelWidth: CGFloat = 44
    /// Fixed width of the unscheduled rail column.
    private static let railWidth: CGFloat = 200

    /// Block layout gutters (#2): left inset clears the hour-label column, trailing
    /// leaves a small right margin, and `columnGap` is the seam between two
    /// side-by-side blocks in an overlap cluster.
    private static let blockGutter: CGFloat = hourLabelWidth + 12
    private static let blockTrailing: CGFloat = 8
    private static let columnGap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: same date label the menubar shows (shared model).
            HStack {
                Text("Today · \(model.list.dateLabel)")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // All-day chips (deadlines, PTO, holidays) — the signal the timed axis
            // can't carry; mirrors the menubar section's chip row.
            allDayChipRow

            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Time axis: the day's gridlines + positioned blocks + drop layer,
                // scrolled to the hour above NOW on open (was a fixed hour-7).
                // TimelineView re-evaluates every minute so the current-time line
                // tracks and past blocks dim without any manual timer plumbing.
                ScrollViewReader { proxy in
                    ScrollView {
                        TimelineView(.everyMinute) { context in
                            axis(asOf: context.date)
                        }
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        proxy.scrollTo("hour-\(model.scrollAnchorHour(at: model.list.badgeAsOf))",
                                       anchor: .top)
                    }
                }

                Divider()

                railView
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        // Drop conflict (T-8-10): the plan-04 continuation seam — Cancel skips
        // the event create (the time: block is already on disk, disk wins);
        // Create anyway commits the event. Double-resolve is structurally
        // impossible (the model nils the continuation before resuming).
        //
        // WR-04: the isPresented setter is INERT — the buttons own the
        // decision (every dismissal path, incl. Esc, routes through the
        // .cancel-role button). A setter that resolved-to-cancel raced the
        // tapped button's action: resolveDropConflict is first-caller-wins,
        // and SwiftUI's setter-vs-action ordering is undocumented, so
        // "Create anyway" could silently become a cancel. Same side-effect-
        // free idiom as the deletePrompt/driftPrompt setters in the menubar.
        // pendingDropConflict is cleared by the model inside
        // resolveDropConflict, which is what flips this binding false.
        .alert("Time conflict",
               isPresented: Binding(
                   get: { model.list.pendingDropConflict != nil },
                   set: { _ in })) {
            Button(model.list.pendingDropConflict?.kind == .move ? "Move anyway" : "Create anyway") {
                model.list.resolveDropConflict(commitAnyway: true)
            }
            Button("Cancel", role: .cancel) { model.list.resolveDropConflict(commitAnyway: false) }
        } message: {
            // Kind-aware copy shared with the popover alert: a drop-move of a scheduled
            // task gates BEFORE writing (cancel changes nothing), a first drop's time:
            // block is already on disk (cancel skips only the event create).
            Text(MenubarListView.conflictMessage(for: model.list.pendingDropConflict))
        }
    }

    // MARK: - Time axis

    private func axis(asOf now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            // Drop layer (CALX-01) at the BOTTOM of the ZStack so it catches
            // drops EVERYWHERE on the axis — over empty space and behind every
            // block. Covers the whole day's axis; y == 0 is exactly dayStart, so
            // `location.y` feeds the tested CanvasLayout.slot math unchanged
            // (T-8-11 — no ad-hoc coordinate→time math here). It sits below the
            // blocks now (was on top) precisely so a TASK block above it can
            // receive its own drag-start instead of this layer swallowing it.
            Color.clear
                .frame(height: model.axisHeight)
                .contentShape(Rectangle())
                .background(dropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                .dropDestination(for: String.self) { ids, location in
                    guard let id = ids.first else { return false }
                    model.list.dropTask(id: id, atSlot: model.slot(atY: location.y))
                    return true
                } isTargeted: { dropTargeted = $0 }

            // Scroll anchors with REAL layout geometry: `.offset` moves only the
            // RENDERING of the labels below, not the frame `scrollTo` targets — every
            // offset label's layout frame sat at the axis top, so scroll-to-hour
            // silently no-oped (a latent bug since the fixed `hour-7` days). Each
            // invisible segment's frame spans [its mark's y, the next mark's y), so
            // `scrollTo("hour-N", anchor: .top)` lands exactly on the gridline.
            VStack(spacing: 0) {
                let marks = model.hourMarks
                ForEach(Array(marks.enumerated()), id: \.element.idx) { i, mark in
                    Color.clear
                        .frame(height: max(0, (i + 1 < marks.count
                                               ? marks[i + 1].y
                                               : model.axisHeight) - mark.y))
                        .id("hour-\(mark.idx)")
                }
            }
            .frame(height: model.axisHeight, alignment: .top)
            .allowsHitTesting(false)

            // Hour gridlines + labels at their REAL wall-clock instants (0…24 so the
            // day is visibly closed): on a DST 25h/23h day the label sits exactly
            // where the physical drop-slot math resolves that wall-clock hour —
            // fixed `hour × scale` offsets disagreed with stored times by an hour
            // after the transition, and clipped the last hour of a fall-back day.
            // Render-only: they sit ABOVE the drop layer, so they must not
            // intercept drops meant for the layer beneath them.
            ForEach(model.hourMarks) { mark in
                HStack(spacing: 6) {
                    Text(mark.label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: Self.hourLabelWidth, alignment: .trailing)
                    VStack(spacing: 0) { Divider() }
                }
                .offset(y: mark.y - 7)
                .allowsHitTesting(false)
            }

            // Positioned blocks ABOVE the drop layer, packed into side-by-side
            // columns so overlapping events/tasks never stack on top of each other
            // (#2). GeometryReader reads the axis width; each block is
            // `usable/columnCount` wide, offset by its column. A TASK block is
            // DRAGGABLE (its bare task id) so re-dropping it onto the axis MOVES it
            // via the existing model path (dropTask → editTime: same id, no duplicate
            // event). An EVENT block opens Calendar.app at its day on tap (parity
            // with the menubar rows). Blocks that ENDED before `now` render dimmed.
            GeometryReader { geo in
                let usable = max(0, geo.size.width - Self.blockGutter - Self.blockTrailing)
                ForEach(model.blocks) { block in
                    let colWidth = usable / CGFloat(max(1, block.columnCount))
                    positionedBlock(block)
                        .frame(width: max(0, colWidth - Self.columnGap), alignment: .topLeading)
                        .opacity(block.end < now ? 0.55 : 1)
                        .offset(x: Self.blockGutter + CGFloat(block.column) * colWidth,
                                y: block.y)
                }
            }
            .frame(height: model.axisHeight)

            // Current-time indicator: the classic red line + dot, tracking via the
            // wrapping TimelineView's minute cadence. Nothing outside today.
            if let nowY = model.nowY(at: now) {
                HStack(spacing: 0) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                    Rectangle()
                        .fill(.red)
                        .frame(height: 1)
                }
                .padding(.leading, Self.hourLabelWidth + 8)
                .offset(y: nowY - 3.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: model.axisHeight, alignment: .top)
    }

    // MARK: - All-day chips

    /// One capsule per (visible) all-day event, horizontally scrollable; tapping
    /// opens Calendar.app at the day. Mirrors the menubar section's chip row.
    @ViewBuilder
    private var allDayChipRow: some View {
        if !model.list.visibleAllDayEvents.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.list.visibleAllDayEvents) { event in
                        Button(action: {
                            if let url = CalendarURL.show(for: event.start) {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
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
            .padding(.bottom, 6)
        }
    }

    /// Wraps a positioned block with kind-specific interactivity.
    ///
    /// TASK blocks get `.draggable(bareTaskID)` + their OWN `.dropDestination`.
    /// The drag makes the block re-grabbable; the per-block drop is the robust
    /// fallback for the case where a drop released directly ON a block does not
    /// fall through to the full-axis layer beneath (SwiftUI hit-testing does not
    /// guarantee fall-through past an interactive/draggable view). Both paths end
    /// in the SAME model call, so a drop resolves identically wherever it lands.
    ///
    /// The per-block drop converts the block-local `location.y` to the axis
    /// coordinate the drop layer uses by ADDING `block.y` — the block's top on
    /// the axis, computed by the tested `CanvasLayout.y`. `block.y` and the drop
    /// layer share one origin (dayStart at y==0), so `block.y + location.y` is
    /// the exact axis y; it is a composition of tested layout values, NOT ad-hoc
    /// coordinate→time math (T-8-11 stays intact — `model.slot(atY:)` still owns
    /// the y→slot inversion; the conflict alert flow is unchanged).
    @ViewBuilder
    private func positionedBlock(_ block: CalendarCanvasModel.Block) -> some View {
        if block.kind == .task, let taskID = block.taskID {
            blockView(block)
                .draggable(taskID)
                .dropDestination(for: String.self) { ids, location in
                    guard let id = ids.first else { return false }
                    model.list.dropTask(id: id,
                                        atSlot: model.slot(atY: block.y + location.y))
                    return true
                } isTargeted: { dropTargeted = $0 }
                .accessibilityElement()
                .accessibilityLabel("Scheduled task: \(block.title)")
                .accessibilityHint("Draggable. Drag onto the time axis to reschedule.")
        } else {
            // EVENT block: tap opens Calendar.app at the event's day — parity with
            // the menubar rows, which have always been tappable. Now that it's
            // hit-testable it must ALSO be a dropDestination: SwiftUI does not
            // guarantee a drop falls through an interactive view to the axis layer
            // beneath, so without this a drop released over an event was swallowed.
            blockView(block)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url = CalendarURL.show(for: block.start) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .dropDestination(for: String.self) { ids, location in
                    guard let id = ids.first else { return false }
                    model.list.dropTask(id: id,
                                        atSlot: model.slot(atY: block.y + location.y))
                    return true
                } isTargeted: { dropTargeted = $0 }
                .accessibilityElement()
                .accessibilityLabel("Event: \(block.title)")
                .accessibilityHint("Opens Calendar.")
        }
    }

    /// One positioned block. Events and tasks are visually DISTINCT: events
    /// render in the accent blue family with a `calendar` glyph, time-blocked
    /// tasks in green with a `checklist` glyph (kind is the tested contract;
    /// the styling hangs off it).
    private func blockView(_ block: CalendarCanvasModel.Block) -> some View {
        let tint: Color = block.kind == .event ? .blue : .green
        return HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: block.kind == .event ? "calendar" : "checklist")
                        .font(.caption2)
                        .foregroundStyle(tint)
                    Text(block.title)
                        .font(.callout)
                        .lineLimit(1)
                }
                // Time range only when the block is tall enough to carry it.
                if block.height >= 34 {
                    Text("\(model.list.timeFormatter.string(from: block.start))–\(model.list.timeFormatter.string(from: block.end))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: block.height, maxHeight: block.height,
               alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        // Width + x/y placement are applied by the caller (column packing, #2), so
        // the block fills whatever column width it is given.
    }

    // MARK: - Unscheduled rail

    /// The draggable rail: each row drags its task **id** as a bare String
    /// (RESEARCH §Drag-to-time-block — String is Transferable, no custom
    /// UTType; the model re-resolves the Todo on drop).
    private var railView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unscheduled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.rail.isEmpty {
                Text("Nothing to schedule — every task has a time.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.rail, id: \.id) { task in
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(task.text)
                                    .font(.callout)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.08)))
                            .contentShape(Rectangle())
                            .draggable(task.id)
                            .help("Drag onto the time axis to schedule")
                            .accessibilityLabel("Unscheduled task: \(task.text)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Self.railWidth, alignment: .topLeading)
    }

}

// MARK: - Window controller

/// The canvas window (RESEARCH A3: a dedicated `NSWindow` over a popover —
/// popover drag/focus is fragile). Mirrors the Settings/Capture window idiom:
/// an `NSHostingController`-backed window, accessory-activation friendly
/// (`show()` activates the app explicitly, same as Settings).
@MainActor
final class CalendarCanvasWindowController: NSWindowController {
    /// Wraps the SHARED menubar list model (same store/calendar/now()), so the
    /// canvas sees exactly what the dropdown sees and a drop's trailing reload
    /// refreshes both surfaces.
    init(list: MenubarListModel) {
        let host = NSHostingController(
            rootView: CalendarCanvasView(model: CalendarCanvasModel(list: list)))
        let win = NSWindow(contentViewController: host)
        win.title = "Jotty — Calendar Canvas"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 620))
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
